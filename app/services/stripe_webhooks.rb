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

    # Find or create recipient user
    recipient = find_or_create_recipient(metadata)

    # Find merchant if specified
    merchant = Merchant.find_by(id: metadata['merchant_id']) if metadata['merchant_id']

    # Create gift card safely
    gift_card = GiftCard.new(
      sender: sender,
      recipient: recipient,
      merchant: merchant,
      amount: session.amount_total, # Stripe gives amount in cents
      currency: session.currency&.upcase || "USD",
      checkout_session_id: session.id,
      expires_at: 1.year.from_now
    )

    # Generate code before saving to avoid validation error
    raw_code = gift_card.generate_code!

    # Create purchase transaction only if association exists
    if gift_card.respond_to?(:transactions)
      gift_card.transactions.create!(
        amount: gift_card.amount,
        txn_type: :purchase,
        status: :succeeded,
        processor_ref: session.payment_intent || "session_#{session.id}",
        metadata: {
          stripe_session_id: session.id,
          stripe_payment_intent: session.payment_intent,
          customer_email: session.customer_email
        }
      )
    else
      Rails.logger.warn "⚠️ GiftCard #{gift_card.id} has no transactions association"
    end

    # Enqueue notification (use perform_now if Sidekiq is not available)
    begin
      NotificationJob.perform_async(gift_card.id, raw_code)
    rescue NoMethodError
      # Fallback to synchronous execution if Sidekiq is not available
      NotificationJob.perform_now(gift_card.id, raw_code)
    end

    Rails.logger.info "✅ Created gift card #{gift_card.id} for session #{session.id}"
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

    # Try to find by phone first
    if phone.present?
      recipient = User.find_by(phone: phone)
      return recipient if recipient
    end

    # Try to find by email
    if email.present?
      recipient = User.find_by(email: email)
      return recipient if recipient
    end

    # Create new user with minimal info
    User.create!(
      name: metadata['recipient_name'] || 'Gift Card Recipient',
      email: email || "gift_recipient_#{SecureRandom.hex(8)}@example.com",
      phone: phone,
      password: SecureRandom.hex(16),
      role: :user
    )
  end
end
