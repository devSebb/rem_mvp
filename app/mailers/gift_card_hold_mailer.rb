class GiftCardHoldMailer < ApplicationMailer
  # Sent to the BUYER when a security hold is placed on a gift card they
  # just purchased. Triggered from StripeWebhooks when risk_score >= 65.
  # Transparent communication reduces support volume ("why isn't my
  # recipient getting the card?") and signals to fraudsters we're watching.
  def held(gift_card_id)
    @gift_card = GiftCard.find(gift_card_id)
    @buyer = @gift_card.sender
    @recipient_label = @gift_card.recipient&.full_name.presence ||
                       @gift_card.recipient&.email.presence ||
                       "tu destinatario"
    @amount_formatted = format("$%.2f %s", @gift_card.amount / 100.0, @gift_card.currency)
    @unlock_time = @gift_card.held_until
    @support_email = ENV['DEFAULT_FROM_EMAIL'].presence || 'hola@papayal.app'

    # Skip placeholder-email pending users — they signed up via gift card
    # receipt with no real email; nothing to send to.
    return if @buyer&.placeholder_email?

    mail(
      to: @buyer.email,
      subject: "Tu compra está bajo revisión de seguridad"
    )
  end
end
