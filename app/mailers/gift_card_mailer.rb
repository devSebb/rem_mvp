class GiftCardMailer < ApplicationMailer
  layout "branded_mailer"
  default from: ENV['DEFAULT_FROM_EMAIL'] || 'hola@papayal.app'

  def deliver_gift_card(gift_card)
    @gift_card = gift_card
    @recipient = gift_card.recipient
    @sender = gift_card.sender
    # Universal link: opens the app when installed, otherwise the branded
    # claim page with the app-download funnel. Replaces the old web-wallet
    # URL, which redirected consumers to /proximamente.
    @claim_url = GiftCards::ClaimLink.url_for(gift_card)

    mail(
      to: @recipient.email,
      subject: "🎁 Recibiste una tarjeta de regalo Papayal"
    )
  end
end
