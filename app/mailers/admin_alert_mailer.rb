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

  # A Stripe refund (Dashboard or admin) exceeded what was still unredeemed
  # on the load — the excess is money already paid to a merchant (§5.7).
  def over_refund(gift_card_id, load_id, refund_id, over_refund_cents, currency)
    @gift_card = GiftCard.find(gift_card_id)
    @load_id = load_id
    @refund_id = refund_id
    @amount_formatted = format("$%.2f %s", over_refund_cents / 100.0, currency)

    mail(
      to: admin_recipient,
      subject: "[ALERT] Over-refund #{@amount_formatted} on gift card ##{@gift_card.id} (load ##{load_id})"
    )
  end

  # A merchant reversal could not put all the cents back on the load it
  # debited (the load was refunded/written off since); an admin_adjustment
  # load was created for the shortfall (§5.5) — the only path that creates
  # money out of order.
  def reversal_shortfall(gift_card_id, reversal_transaction_id, shortfall_cents)
    @gift_card = GiftCard.find(gift_card_id)
    @reversal_transaction_id = reversal_transaction_id
    @amount_formatted = format("$%.2f %s", shortfall_cents / 100.0, @gift_card.currency)

    mail(
      to: admin_recipient,
      subject: "[ALERT] Reversal shortfall #{@amount_formatted} on gift card ##{@gift_card.id}"
    )
  end

  # A buyer lost a second chargeback and was blocked from purchasing (§5.8).
  def buyer_purchases_blocked(user_id, stripe_dispute_id)
    @user = User.find(user_id)
    @dispute_id = stripe_dispute_id

    mail(
      to: admin_recipient,
      subject: "[DISPUTE] Buyer ##{@user.id} blocked after #{@user.dispute_lost_count} lost disputes"
    )
  end

  # Nightly Ledger::ReconcileJob found drift (§4.6). `summary` is the hash
  # the job stores (primitives only, deliver_later-safe).
  def ledger_drift(summary)
    @summary = summary
    @drift_lines = Array(summary[:drift] || summary["drift"])

    mail(
      to: admin_recipient,
      subject: "[ALERT] Ledger drift: #{summary[:drift_count] || summary['drift_count']} issue(s) on #{summary[:cards_checked] || summary['cards_checked']} cards"
    )
  end

  # §4.5: potential CFPB remittance transfers are approaching the 500/year
  # safe harbor. `summary` is Loads::RemittanceCounter.summary (primitives).
  def remittance_threshold(summary)
    @summary = summary.symbolize_keys

    mail(
      to: admin_recipient,
      subject: "[ALERT] Remittance counter at #{@summary[:current_year]} loads in #{@summary[:year]} (safe harbor #{@summary[:safe_harbor]})"
    )
  end

  private

  def admin_recipient
    ENV['ADMIN_ALERT_EMAIL'].presence || ENV['DEFAULT_FROM_EMAIL'].presence || 'hola@papayal.app'
  end
end
