class AdminAlertMailer < ApplicationMailer
  # Internal alerts to the admin team. Recipient comes from
  # ENV['ADMIN_ALERT_EMAIL'] (e.g., hola@papayal.app forwarded via
  # Cloudflare Email Routing). Subject prefixed [DISPUTE]/[ALERT] for
  # easy Gmail filtering.

  def dispute_created(gift_card_id, stripe_dispute_id)
    @gift_card = GiftCard.find(gift_card_id)
    @dispute_id = stripe_dispute_id
    @amount_formatted = format("$%.2f %s", @gift_card.amount / 100.0, @gift_card.currency)

    mail(
      to: admin_recipient,
      subject: "[DISPUTE] Gift card ##{@gift_card.id} — chargeback filed"
    )
  end

  def dispute_closed(gift_card_id, stripe_dispute_id, status)
    @gift_card = GiftCard.find(gift_card_id)
    @dispute_id = stripe_dispute_id
    @status = status
    @amount_formatted = format("$%.2f %s", @gift_card.amount / 100.0, @gift_card.currency)

    mail(
      to: admin_recipient,
      subject: "[DISPUTE] Gift card ##{@gift_card.id} — dispute closed (#{status})"
    )
  end

  private

  def admin_recipient
    ENV['ADMIN_ALERT_EMAIL'].presence || ENV['DEFAULT_FROM_EMAIL'].presence || 'hola@papayal.app'
  end
end
