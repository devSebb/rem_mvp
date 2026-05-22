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
    when 'payment_intent.succeeded'
      handle_payment_intent_succeeded(event.data.object)
    else
      Rails.logger.info "Unhandled event type: #{event.type}"
    end
  end

  private

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
        enqueue_notification(existing_gift_card.id, raw_code)
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
      expires_at: nil, # Gift cards never expire
      note: metadata['recipient_note'].presence
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

    enqueue_notification(gift_card.id, raw_code)

    Rails.logger.info "✅ Successfully created gift card #{gift_card.id} for payment intent #{payment_intent.id}"
    Rails.logger.info "   Recipient: #{recipient.email}, Amount: #{gift_card.currency} #{gift_card.amount / 100.0}"
  rescue => e
    Rails.logger.error "💥 Error handling payment_intent.succeeded: #{e.class} - #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise # re-raise so you still see the 500 during dev
  end

  # Enqueue notification job. In production we never block the webhook on sync send;
  # in development/test we fall back to perform_now if Sidekiq/Redis is unavailable.
  def self.enqueue_notification(gift_card_id, raw_code)
    NotificationJob.perform_later(gift_card_id, raw_code)
    Rails.logger.info "📤 Enqueued notification job for gift card #{gift_card_id} (async)"
  rescue NoMethodError, Redis::CannotConnectError => e
    if Rails.env.production?
      Rails.logger.error "❌ Sidekiq/Redis unavailable (#{e.class}); notification not sent for gift_card_id=#{gift_card_id}. Fix Redis and retry manually if needed."
      # Do not block webhook; notification can be retried via support or cron
    else
      Rails.logger.warn "⚠️ Sidekiq not available (#{e.class}), sending notification synchronously"
      NotificationJob.perform_now(gift_card_id, raw_code)
      Rails.logger.info "📤 Sent notification for gift card #{gift_card_id} (sync)"
    end
  rescue => e
    Rails.logger.error "❌ Failed to enqueue/send notification: #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n")
  end

  def self.find_or_create_recipient(metadata)
    phone = metadata['recipient_phone'].presence
    email = metadata['recipient_email'].presence&.downcase

    Rails.logger.info "🔍 Looking for recipient with email: #{email || '(none)'}, phone: #{phone || '(none)'}"

    # Try to find existing user by phone first, then email.
    if phone.present?
      recipient = User.find_by(phone: phone)
      if recipient
        Rails.logger.info "✅ Found recipient by phone: user_id=#{recipient.id} pending=#{recipient.pending?}"
        return recipient
      end
    end

    if email.present?
      recipient = User.find_by(email: email)
      if recipient
        Rails.logger.info "✅ Found recipient by email: user_id=#{recipient.id} pending=#{recipient.pending?}"
        return recipient
      end
    end

    # Refuse to create without at least one real contact channel.
    if email.blank? && phone.blank?
      Rails.logger.error "❌ Cannot create recipient: both email and phone are blank"
      return nil
    end

    # Create a pending recipient. claimed_at: nil signals "not signed up yet";
    # validations on first_name/last_name/phone are skipped while pending.
    # If only phone was provided, we synthesize a placeholder email so Devise
    # :validatable (which requires email format) is satisfied. The placeholder
    # is detected by Notifier and skipped for real email delivery.
    recipient_name = metadata['recipient_name'].presence
    name_parts = recipient_name.to_s.split(/\s+/, 2)
    first_name = name_parts[0].presence
    last_name = name_parts[1].presence
    effective_email = email || User.placeholder_email_for_phone(phone)

    recipient = User.create!(
      name: recipient_name,
      first_name: first_name,
      last_name: last_name,
      email: effective_email,
      phone: phone,
      password: SecureRandom.hex(32),
      role: :user,
      pending_recipient: true,
      skip_national_id_validation: true
    )
    Rails.logger.info "✅ Created pending recipient: user_id=#{recipient.id} email=#{recipient.email} phone=#{recipient.phone || '(none)'}"
    recipient
  end
end
