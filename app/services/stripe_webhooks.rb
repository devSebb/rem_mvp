class StripeWebhooks
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

    # Find merchant if specified
    merchant = Merchant.find_by(id: metadata['merchant_id']) if metadata['merchant_id']
    Rails.logger.info "✅ Merchant: #{merchant ? merchant.store_name : 'none'}"

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

    # Create gift card safely
    gift_card = GiftCard.create!(
      sender: sender,
      recipient: recipient,
      merchant: merchant,
      amount: session.amount_total, # Stripe gives amount in cents
      currency: session.currency&.upcase || "USD",
      checkout_session_id: session.id,
      expires_at: 1.year.from_now
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
        NotificationJob.perform_async(gift_card.id, raw_code)
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
    Rails.logger.info "💳 Payment intent succeeded: #{payment_intent.id}"
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

    recipient = User.create!(
      name: metadata['recipient_name'] || 'Gift Card Recipient',
      email: email || "gift_recipient_#{SecureRandom.hex(8)}@example.com",
      phone: phone,
      password: SecureRandom.hex(16),
      role: :user,
      skip_national_id_validation: true
    )
    Rails.logger.info "✅ Created new recipient: #{recipient.email}"
    recipient
  end
end
