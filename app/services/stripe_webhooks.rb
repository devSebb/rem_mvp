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
    
    # Find or create recipient user
    recipient = find_or_create_recipient(metadata)
    
    # Find sender user
    sender = User.find_by(id: metadata['sender_id'])
    return unless sender

    # Find merchant if specified
    merchant = Merchant.find_by(id: metadata['merchant_id']) if metadata['merchant_id']

    # Create gift card
    gift_card = GiftCard.create!(
      sender: sender,
      recipient: recipient,
      merchant: merchant,
      amount: session.amount_total,
      currency: session.currency.upcase,
      checkout_session_id: session.id,
      expires_at: 1.year.from_now
    )

    # Generate code
    raw_code = gift_card.generate_code!

    # Create purchase transaction
    gift_card.transactions.create!(
      amount: gift_card.amount,
      txn_type: :purchase,
      status: :succeeded,
      processor_ref: session.payment_intent,
      metadata: {
        stripe_session_id: session.id,
        stripe_payment_intent: session.payment_intent,
        customer_email: session.customer_email
      }
    )

    # Enqueue notification job
    NotificationJob.perform_async(gift_card.id, raw_code)

    Rails.logger.info "Created gift card #{gift_card.id} for session #{session.id}"
  end

  def self.handle_payment_intent_succeeded(payment_intent)
    # Additional processing if needed
    Rails.logger.info "Payment intent succeeded: #{payment_intent.id}"
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
