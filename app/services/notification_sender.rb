class NotificationSender
  def self.send_gift_card_notification(gift_card, raw_code)
    recipient = gift_card.recipient
    sender = gift_card.sender
    merchant = gift_card.merchant

    message = build_message(gift_card, raw_code, sender, merchant)

    if recipient&.phone.present?
      send_sms(recipient.phone, message)
    elsif recipient&.email.present?
      send_email(recipient.email, message, gift_card)
    else
      Rails.logger.warn "No phone or email for recipient of gift card #{gift_card.id}"
    end
  end

  private

  def self.build_message(gift_card, raw_code, sender, merchant)
    amount = format_amount(gift_card.amount, gift_card.currency)
    store_name = merchant&.store_name || 'our store'
    
    "Has recibido una tarjeta de regalo de #{amount} para #{store_name}. " \
    "Código: #{raw_code}. Muestra este código o QR en caja."
  end

  def self.format_amount(amount_cents, currency)
    case currency.upcase
    when 'USD'
      "$#{amount_cents / 100.0}"
    when 'EUR'
      "€#{amount_cents / 100.0}"
    else
      "#{amount_cents / 100.0} #{currency}"
    end
  end

  def self.send_sms(phone, message)
    return unless Rails.application.config.twilio[:account_sid].present?

    client = Twilio::REST::Client.new(
      Rails.application.config.twilio[:account_sid],
      Rails.application.config.twilio[:auth_token]
    )

    client.messages.create(
      from: Rails.application.config.twilio[:from_number],
      to: phone,
      body: message
    )

    Rails.logger.info "SMS sent to #{phone}"
  rescue => e
    Rails.logger.error "Failed to send SMS to #{phone}: #{e.message}"
  end

  def self.send_email(email, message, gift_card)
    # For MVP, just log the email content
    # In production, you'd use ActionMailer
    Rails.logger.info "Email notification for #{email}:"
    Rails.logger.info "Subject: Gift Card Received"
    Rails.logger.info "Body: #{message}"
    Rails.logger.info "Gift Card ID: #{gift_card.id}"
  end
end
