class GiftCardHoldMailer < ApplicationMailer
  layout "branded_mailer"
  # Sent to the BUYER when a security hold is placed on ONE load they just
  # paid for (§5.9 "hold mailer per load"). Triggered from Loads::Fulfill
  # when Radar's risk_score >= GiftCard::RISK_HOLD_THRESHOLD. The rest of
  # the card's balance stays spendable (D5).
  def held(gift_card_load_id)
    @load = GiftCardLoad.find(gift_card_load_id)
    @gift_card = @load.gift_card
    @buyer = @load.sender
    @recipient_label = @gift_card.recipient&.full_name.presence ||
                       @gift_card.recipient&.email.presence ||
                       "tu destinatario"
    @amount_formatted = Messaging::Money.format(@load.amount_cents, currency: @load.currency)
    @unlock_time = @load.held_until
    @support_email = ENV['DEFAULT_FROM_EMAIL'].presence || 'hola@papayal.app'

    # Skip placeholder-email pending users — nothing deliverable to send to.
    return if @buyer.nil? || @buyer.email.blank? || @buyer.placeholder_email?

    mail(
      to: @buyer.email,
      subject: "Tu recarga está bajo revisión de seguridad"
    )
  end
end
