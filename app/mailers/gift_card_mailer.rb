class GiftCardMailer < ApplicationMailer
  layout "branded_mailer"
  default from: ENV['DEFAULT_FROM_EMAIL'] || 'hola@papayal.app'

  # Recipient-facing delivery of ONE load (§5.9): the first load on a card
  # announces the gift card, a later one announces the reload and the
  # spendable balance. Takes the load id so deliver_later serializes cleanly.
  def deliver_gift_card(load_or_id)
    @load = load_or_id.is_a?(GiftCardLoad) ? load_or_id : GiftCardLoad.find(load_or_id)
    @gift_card = @load.gift_card
    @recipient = @gift_card.recipient
    @sender = @load.sender
    @merchant_name = @gift_card.merchant&.store_name || "Papayal"
    @sender_name = @sender&.first_name.presence || @sender&.name.presence || "Alguien"
    @amount_label = Messaging::Money.format(@load.amount_cents, currency: @load.currency)
    @first_load = @gift_card.loads.in_scope.fifo.first&.id == @load.id
    @spendable_label = Messaging::Money.format(@gift_card.spendable_cents, currency: @gift_card.currency)
    # Universal link: opens the app when installed, otherwise the branded
    # claim page with the app-download funnel.
    @claim_url = GiftCards::ClaimLink.url_for(@load)

    subject =
      if @first_load
        "🎁 Recibiste una tarjeta de regalo digital de #{@merchant_name}"
      else
        "#{@sender_name} recargó tu tarjeta de #{@merchant_name} con #{@amount_label}"
      end

    mail(to: @recipient.email, subject: subject)
  end
end
