class StripeWebhooks
  class InvalidMerchantError < StandardError; end

  def self.verify_signature(payload, signature)
    webhook_secret = Rails.application.config.stripe[:webhook_secret]
    return false if webhook_secret.blank?

    begin
      Stripe::Webhook.construct_event(payload, signature, webhook_secret)
    rescue Stripe::SignatureVerificationError
      false
    end
  end

  def self.process_event(event)
    case event.type
    when 'checkout.session.completed'
      handle_checkout_session_completed(event.data.object)
    when 'payment_intent.succeeded'
      handle_payment_intent_succeeded(event.data.object)
    else
      Rails.logger.info "Unhandled event type: #{event.type}"
    end
  end

  private

  def self.handle_checkout_session_completed(session)
    metadata = session.metadata || {}
    Rails.logger.info "🔔 checkout.session.completed received with metadata: #{metadata.inspect}"
    merchant_id_raw = metadata["merchant_id"]
    merchant_id = merchant_id_raw.to_s.strip

    if merchant_id.blank?
      Rails.logger.error "❌ Missing merchant_id for session #{session.id}"
      raise InvalidMerchantError, "Missing merchant for session #{session.id}"
    end

    unless merchant_id.match?(/\A\d+\z/)
      Rails.logger.error "❌ Non-numeric merchant_id #{merchant_id.inspect} for session #{session.id}"
      raise InvalidMerchantError, "Invalid merchant for session #{session.id}"
    end

    merchant = Merchant.find_by(id: merchant_id)
    unless merchant
      Rails.logger.error "❌ Invalid merchant_id #{merchant_id} for session #{session.id}"
      raise InvalidMerchantError, "Invalid merchant for session #{session.id}"
    end

    # Find sender user
    sender = User.find_by(id: metadata['sender_id'])
    unless sender
      Rails.logger.error "❌ No sender found for session #{session.id} (metadata: #{metadata.inspect})"
      return
    end
    Rails.logger.info "✅ Found sender: #{sender.email} (ID: #{sender.id})"

    # Find or create recipient user
    recipient = find_or_create_recipient(metadata)
    unless recipient
      Rails.logger.error "❌ Failed to find or create recipient for session #{session.id}"
      return
    end
    Rails.logger.info "✅ Found/created recipient: #{recipient.email} (ID: #{recipient.id})"

    Rails.logger.info "✅ Merchant: #{merchant ? merchant.store_name : 'none'}"

    # Validate amount (defense in depth - should already be validated at checkout)
    if session.amount_total > GiftCard::MAX_AMOUNT_CENTS
      Rails.logger.error "❌ Amount exceeds maximum: #{session.amount_total} cents (max: #{GiftCard::MAX_AMOUNT_CENTS})"
      raise InvalidMerchantError, "Amount exceeds maximum allowed per gift card"
    end

    # Validate purchase limit (defense in depth - should already be validated at checkout)
    limit_check = GiftCardPurchaseLimiter.can_purchase?(user: sender)
    unless limit_check[:allowed]
      Rails.logger.error "❌ Purchase limit exceeded for user #{sender.id}: #{limit_check[:count]}/#{limit_check[:limit]} in last 24h"
      raise InvalidMerchantError, "Purchase limit exceeded: #{limit_check[:reason]}"
    end

    # Check if gift card already exists for this session (idempotency)
    existing_gift_card = GiftCard.find_by(checkout_session_id: session.id)
    if existing_gift_card
      Rails.logger.warn "⚠️ Gift card already exists for session #{session.id} (ID: #{existing_gift_card.id})"
      Rails.logger.info "   Skipping creation, but will attempt to send notification if not sent yet"
      
      # Try to send notification if it wasn't sent yet
      if !existing_gift_card.sent_via_email && !existing_gift_card.sent_via_sms && !existing_gift_card.sent_via_whatsapp
        raw_code = existing_gift_card.generate_code!
        begin
          NotificationJob.perform_now(existing_gift_card.id, raw_code)
        rescue => e
          Rails.logger.error "❌ Failed to send notification for existing gift card: #{e.message}"
        end
      end
      
      return
    end

    # Create gift card safely (no expiration - gift cards never expire)
    gift_card = GiftCard.create!(
      sender: sender,
      recipient: recipient,
      merchant: merchant,
      amount: session.amount_total, # Stripe gives amount in cents
      currency: session.currency&.upcase || "USD",
      checkout_session_id: session.id,
      expires_at: nil # Gift cards never expire
    )

    # Generate code after saving
    raw_code = gift_card.generate_code!
    Rails.logger.info "✅ Generated gift card code for gift card #{gift_card.id}"

    # Create purchase transaction only if association exists
    if gift_card.respond_to?(:transactions)
      gift_card.transactions.create!(
        amount: gift_card.amount,
        txn_type: :purchase,
        status: :succeeded,
        processor_ref: session.payment_intent || "session_#{session.id}",
        merchant: merchant,
        user: sender,
        currency: gift_card.currency,
        metadata: {
          stripe_session_id: session.id,
          stripe_payment_intent: session.payment_intent,
          customer_email: session.customer_email
        }
      )
      Rails.logger.info "✅ Created purchase transaction for gift card #{gift_card.id}"
    else
      Rails.logger.warn "⚠️ GiftCard #{gift_card.id} has no transactions association"
    end

    # Enqueue notification (use perform_now if Sidekiq is not available)
    begin
      # Try async first, fallback to sync if Sidekiq not available
      begin
        NotificationJob.perform_later(gift_card.id, raw_code)
        Rails.logger.info "📤 Enqueued notification job for gift card #{gift_card.id} (async)"
      rescue NoMethodError, Redis::CannotConnectError => e
        # Sidekiq not available or Redis not running - use sync
        Rails.logger.warn "⚠️ Sidekiq not available (#{e.class}), sending notification synchronously"
        NotificationJob.perform_now(gift_card.id, raw_code)
        Rails.logger.info "📤 Sent notification for gift card #{gift_card.id} (sync)"
      end
    rescue => e
      Rails.logger.error "❌ Failed to send notification: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      # Don't fail the webhook if notification fails
    end

    Rails.logger.info "✅ Successfully created gift card #{gift_card.id} for session #{session.id}"
    Rails.logger.info "   Recipient: #{recipient.email}, Amount: #{gift_card.currency} #{gift_card.amount / 100.0}"
  rescue => e
    Rails.logger.error "💥 Error handling checkout.session.completed: #{e.class} - #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise # re-raise so you still see the 500 during dev
  end

  def self.handle_payment_intent_succeeded(payment_intent)
    metadata = payment_intent.metadata || {}
    Rails.logger.info "💳 Payment intent succeeded: #{payment_intent.id} with metadata: #{metadata.inspect}"
    
    merchant_id_raw = metadata["merchant_id"]
    merchant_id = merchant_id_raw.to_s.strip

    if merchant_id.blank?
      Rails.logger.error "❌ Missing merchant_id for payment intent #{payment_intent.id}"
      raise InvalidMerchantError, "Missing merchant for payment intent #{payment_intent.id}"
    end

    unless merchant_id.match?(/\A\d+\z/)
      Rails.logger.error "❌ Non-numeric merchant_id #{merchant_id.inspect} for payment intent #{payment_intent.id}"
      raise InvalidMerchantError, "Invalid merchant for payment intent #{payment_intent.id}"
    end

    merchant = Merchant.find_by(id: merchant_id)
    unless merchant
      Rails.logger.error "❌ Invalid merchant_id #{merchant_id} for payment intent #{payment_intent.id}"
      raise InvalidMerchantError, "Invalid merchant for payment intent #{payment_intent.id}"
    end

    # Find sender user
    sender = User.find_by(id: metadata['sender_id'])
    unless sender
      Rails.logger.error "❌ No sender found for payment intent #{payment_intent.id} (metadata: #{metadata.inspect})"
      return
    end
    Rails.logger.info "✅ Found sender: #{sender.email} (ID: #{sender.id})"

    # Find or create recipient user
    recipient = find_or_create_recipient(metadata)
    unless recipient
      Rails.logger.error "❌ Failed to find or create recipient for payment intent #{payment_intent.id}"
      return
    end
    Rails.logger.info "✅ Found/created recipient: #{recipient.email} (ID: #{recipient.id})"

    Rails.logger.info "✅ Merchant: #{merchant ? merchant.store_name : 'none'}"

    # Validate amount (defense in depth - should already be validated at checkout)
    if payment_intent.amount > GiftCard::MAX_AMOUNT_CENTS
      Rails.logger.error "❌ Amount exceeds maximum: #{payment_intent.amount} cents (max: #{GiftCard::MAX_AMOUNT_CENTS})"
      raise InvalidMerchantError, "Amount exceeds maximum allowed per gift card"
    end

    # Validate purchase limit (defense in depth - should already be validated at checkout)
    limit_check = GiftCardPurchaseLimiter.can_purchase?(user: sender)
    unless limit_check[:allowed]
      Rails.logger.error "❌ Purchase limit exceeded for user #{sender.id}: #{limit_check[:count]}/#{limit_check[:limit]} in last 24h"
      raise InvalidMerchantError, "Purchase limit exceeded: #{limit_check[:reason]}"
    end

    # Check if gift card already exists for this payment intent (idempotency)
    existing_gift_card = GiftCard.find_by(payment_intent_id: payment_intent.id)
    if existing_gift_card
      Rails.logger.warn "⚠️ Gift card already exists for payment intent #{payment_intent.id} (ID: #{existing_gift_card.id})"
      Rails.logger.info "   Skipping creation, but will attempt to send notification if not sent yet"
      
      # Try to send notification if it wasn't sent yet
      if !existing_gift_card.sent_via_email && !existing_gift_card.sent_via_sms && !existing_gift_card.sent_via_whatsapp
        raw_code = existing_gift_card.generate_code!
        begin
          NotificationJob.perform_now(existing_gift_card.id, raw_code)
        rescue => e
          Rails.logger.error "❌ Failed to send notification for existing gift card: #{e.message}"
        end
      end
      
      return
    end

    # Create gift card safely (no expiration - gift cards never expire)
    gift_card = GiftCard.create!(
      sender: sender,
      recipient: recipient,
      merchant: merchant,
      amount: payment_intent.amount, # Stripe gives amount in cents
      currency: payment_intent.currency&.upcase || "USD",
      payment_intent_id: payment_intent.id,
      expires_at: nil # Gift cards never expire
    )

    # Generate code after saving
    raw_code = gift_card.generate_code!
    Rails.logger.info "✅ Generated gift card code for gift card #{gift_card.id}"

    # Create purchase transaction only if association exists
    if gift_card.respond_to?(:transactions)
      gift_card.transactions.create!(
        amount: gift_card.amount,
        txn_type: :purchase,
        status: :succeeded,
        processor_ref: payment_intent.id,
        merchant: merchant,
        user: sender,
        currency: gift_card.currency,
        metadata: {
          stripe_payment_intent_id: payment_intent.id,
          customer_email: payment_intent.receipt_email
        }
      )
      Rails.logger.info "✅ Created purchase transaction for gift card #{gift_card.id}"
    else
      Rails.logger.warn "⚠️ GiftCard #{gift_card.id} has no transactions association"
    end

    # Enqueue notification (use perform_now if Sidekiq is not available)
    begin
      # Try async first, fallback to sync if Sidekiq not available
      begin
        NotificationJob.perform_later(gift_card.id, raw_code)
        Rails.logger.info "📤 Enqueued notification job for gift card #{gift_card.id} (async)"
      rescue NoMethodError, Redis::CannotConnectError => e
        # Sidekiq not available or Redis not running - use sync
        Rails.logger.warn "⚠️ Sidekiq not available (#{e.class}), sending notification synchronously"
        NotificationJob.perform_now(gift_card.id, raw_code)
        Rails.logger.info "📤 Sent notification for gift card #{gift_card.id} (sync)"
      end
    rescue => e
      Rails.logger.error "❌ Failed to send notification: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      # Don't fail the webhook if notification fails
    end

    Rails.logger.info "✅ Successfully created gift card #{gift_card.id} for payment intent #{payment_intent.id}"
    Rails.logger.info "   Recipient: #{recipient.email}, Amount: #{gift_card.currency} #{gift_card.amount / 100.0}"
  rescue => e
    Rails.logger.error "💥 Error handling payment_intent.succeeded: #{e.class} - #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise # re-raise so you still see the 500 during dev
  end

  def self.find_or_create_recipient(metadata)
    phone = metadata['recipient_phone']
    email = metadata['recipient_email']

    Rails.logger.info "🔍 Looking for recipient with email: #{email}, phone: #{phone}"

    # Try to find by phone first
    if phone.present?
      recipient = User.find_by(phone: phone)
      if recipient
        Rails.logger.info "✅ Found recipient by phone: #{recipient.email}"
        return recipient
      end
    end

    # Try to find by email
    if email.present?
      recipient = User.find_by(email: email)
      if recipient
        Rails.logger.info "✅ Found recipient by email: #{recipient.email}"
        return recipient
      end
    end

    # Create new user with minimal info
    if email.blank? && phone.blank?
      Rails.logger.error "❌ Cannot create recipient: both email and phone are blank"
      return nil
    end

    recipient_name = metadata['recipient_name'] || 'Gift Card Recipient'
    # Split name into first_name and last_name if needed
    name_parts = recipient_name.split(/\s+/, 2)
    first_name = name_parts[0] || 'Gift'
    last_name = name_parts[1] || 'Recipient'
    
    recipient = User.create!(
      name: recipient_name,
      first_name: first_name,
      last_name: last_name,
      email: email || "gift_recipient_#{SecureRandom.hex(8)}@example.com",
      phone: phone || "+#{SecureRandom.rand(1..999)}#{SecureRandom.rand(1000000..9999999)}", # Generate phone if missing (random country code + number)
      password: SecureRandom.hex(16),
      role: :user,
      skip_national_id_validation: true
    )
    Rails.logger.info "✅ Created new recipient: #{recipient.email}"
    recipient
  end
end
