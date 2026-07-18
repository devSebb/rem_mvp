class AdminAlertMailer < ApplicationMailer
  layout "branded_mailer"
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

  # A succeeded payment could not be fulfilled as a gift card and was
  # automatically refunded in full (see Refunds::RefundOrphanedPayment).
  # Primitives only so deliver_later serializes cleanly.
  def orphaned_payment_refunded(payment_intent_id, amount_cents, currency, reason, refund_id)
    @payment_intent_id = payment_intent_id
    @reason = reason
    @refund_id = refund_id
    @amount_formatted = format("$%.2f %s", amount_cents / 100.0, currency)

    mail(
      to: admin_recipient,
      subject: "[ALERT] Payment #{payment_intent_id} auto-refunded — fulfillment failed (#{reason})"
    )
  end

  # A Stripe refund we already debited from the card failed at the bank.
  # The card was restored, but the buyer did NOT get their money back —
  # support follow-up needed. Primitives only for deliver_later.
  def refund_failed(gift_card_id, refund_id, amount_cents, currency, failure_reason)
    @gift_card = GiftCard.find(gift_card_id)
    @refund_id = refund_id
    @failure_reason = failure_reason.presence || "unknown"
    @amount_formatted = format("$%.2f %s", amount_cents / 100.0, currency)

    mail(
      to: admin_recipient,
      subject: "[ALERT] Refund #{refund_id} FAILED — gift card ##{@gift_card.id} restored"
    )
  end

  # A buyer's payment attempt was declined. Informational (no money moved,
  # no card exists) — sent at most once per PaymentIntent per day.
  def payment_failed(payment_intent_id, amount_cents, currency, error_code, decline_code, sender_id, merchant_id)
    @payment_intent_id = payment_intent_id
    @error_code = error_code.presence || "unknown"
    @decline_code = decline_code
    @sender = sender_id.present? ? User.find_by(id: sender_id) : nil
    @merchant = merchant_id.present? ? Merchant.find_by(id: merchant_id) : nil
    @amount_formatted = format("$%.2f %s", amount_cents / 100.0, currency)

    mail(
      to: admin_recipient,
      subject: "[ALERT] Payment declined — #{@amount_formatted} (#{@decline_code || @error_code})"
    )
  end

  private

  def admin_recipient
    ENV['ADMIN_ALERT_EMAIL'].presence || ENV['DEFAULT_FROM_EMAIL'].presence || 'hola@papayal.app'
  end
end
