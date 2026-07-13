class GiftCardMailer < ApplicationMailer
  layout "branded_mailer"
  default from: ENV['DEFAULT_FROM_EMAIL'] || 'hola@papayal.app'

  def deliver_gift_card(gift_card)
    @gift_card = gift_card
    @recipient = gift_card.recipient
    @sender = gift_card.sender
    @gift_card_url = gift_card_url(gift_card)

    mail(
      to: @recipient.email,
      subject: "🎁 Recibiste una tarjeta de regalo Papayal"
    )
  end
end
