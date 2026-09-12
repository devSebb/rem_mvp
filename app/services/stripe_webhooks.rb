class StripeWebhooks
  # Raised when a succeeded payment can never be fulfilled as a load
  # (bad/suspended merchant, missing sender/recipient, cap exceeded,
  # canceled/frozen card, invalid data). These are PERMANENT failures:
  # retrying the webhook will not fix them, so the money must go back to the
  # buyer instead of being stranded. Transient errors (DB/Redis down) are
  # deliberately NOT mapped to this class — they re-raise so Stripe retries.
  class UnfulfillablePaymentError < StandardError
    attr_reader :reason

    def initialize(reason, message)
      @reason = reason
      super(message)
    end
  end

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
    when 'payment_intent.succeeded'
      handle_payment_intent_succeeded(event.data.object)
    when 'payment_intent.payment_failed'
      handle_payment_intent_payment_failed(event.data.object)
    when 'refund.created', 'refund.updated', 'refund.failed'
      handle_refund_event(event.data.object)
    when 'charge.refunded'
      handle_charge_refunded(event.data.object)
    when 'charge.dispute.created'
      handle_charge_dispute_created(event.data.object)
    when 'charge.dispute.closed'
      handle_charge_dispute_closed(event.data.object)
    else
      Rails.logger.info "Unhandled event type: #{event.type}"
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # payment_intent.succeeded → one load on the recipient's card (§5.2).
  # ──────────────────────────────────────────────────────────────────────
  def self.handle_payment_intent_succeeded(payment_intent)
    fulfill_payment_intent!(payment_intent)
    mark_payment_failures_resolved(payment_intent)
  rescue UnfulfillablePaymentError => e
    refund_unfulfillable_payment(payment_intent, e)
  end

  def self.fulfill_payment_intent!(payment_intent)
    Loads::Fulfill.call(payment_intent)
  end

  # A PI that failed earlier and now succeeded means the buyer retried and
  # got through — close the decline record. Never lets bookkeeping break
  # fulfillment.
  def self.mark_payment_failures_resolved(payment_intent)
    PaymentFailure.unresolved
                  .where(payment_intent_id: payment_intent.id)
                  .update_all(resolved_at: Time.current)
  rescue => e
    Rails.logger.error "[PaymentFailed] Could not mark #{payment_intent.try(:id)} resolved: #{e.class} - #{e.message}"
  end

  def self.refund_unfulfillable_payment(payment_intent, error)
    Rails.logger.error "❌ Unfulfillable payment #{payment_intent.id} (#{error.reason}): #{error.message}"
    Refunds::RefundOrphanedPayment.call(payment_intent: payment_intent, reason: error.reason)
    Rails.logger.info "✅ Auto-refunded unfulfillable payment #{payment_intent.id}"
    # The webhook returns 200 so Stripe stops retrying — the money is back
    # with the buyer. If RefundOrphanedPayment itself raised (Stripe down),
    # that propagates: Stripe re-delivers and the refund is re-attempted.
  rescue Refunds::RefundOrphanedPayment::GiftCardExists
    Rails.logger.warn "⚠️ Load appeared for #{payment_intent.id} while handling failure; skipping refund"
  end

  # Kept for callers that resolve recipients the way fulfilment does.
  def self.find_or_create_recipient(metadata)
    Loads::Fulfill.find_or_create_recipient(metadata)
  end

  # ──────────────────────────────────────────────────────────────────────
  # refund.created / refund.updated / refund.failed — reconcile the LOAD
  # whose PaymentIntent was refunded (§5.7). Triggered for admin refunds
  # (Refunds::IssueStripeRefund) and for refunds issued in the Stripe
  # Dashboard. Idempotent against re-delivery and overlap with
  # charge.refunded: de-duped on stripe_refund_id, backstopped by the unique
  # index on processor_ref. Also called by `rake stripe:reconcile_refunds`.
  # ──────────────────────────────────────────────────────────────────────
  def self.handle_refund_event(refund)
    load = find_load_for_refund(refund)
    return unless load

    case refund.status
    when "succeeded", "pending"
      # `pending` still debits: card refunds almost always settle, and if
      # this one doesn't, refund.failed arrives later and reverses it.
      apply_refund!(load, refund)
    when "failed", "canceled"
      reverse_refund!(load, refund)
    else
      Rails.logger.info "[Refund] Ignoring refund #{refund.id} with status #{refund.status.inspect}"
    end
  rescue => e
    Rails.logger.error "💥 refund event handler error: #{e.class} - #{e.message}"
    Rails.logger.error e.backtrace.first(10).join("\n")
    raise
  end

  # charge.refunded — defensive alias for older payloads and as a second
  # delivery channel. Modern payloads no longer embed the refunds list.
  def self.handle_charge_refunded(charge)
    refunds = charge.try(:refunds).try(:data)
    refunds = Stripe::Refund.list(charge: charge.id).data if refunds.blank?

    Array(refunds).each { |refund| handle_refund_event(refund) }
  rescue => e
    Rails.logger.error "💥 charge.refunded handler error: #{e.class} - #{e.message}"
    Rails.logger.error e.backtrace.first(10).join("\n")
    raise
  end

  def self.find_load_for_refund(refund)
    payment_intent_id = refund.try(:payment_intent)
    if payment_intent_id.blank?
      Rails.logger.warn "[Refund] Refund #{refund.id} has no payment_intent; skipping"
      return nil
    end

    load = GiftCardLoad.for_payment_intent(payment_intent_id)
    unless load
      # Expected for orphaned-payment auto-refunds (no load was ever
      # created — that's the point of the refund).
      Rails.logger.warn "[Refund] No load found for refund #{refund.id} (PI: #{payment_intent_id})"
      return nil
    end

    load
  end

  # Debit the refunded cents from the load's unredeemed part. A Dashboard
  # refund larger than what is still on the load (money already spent at a
  # merchant) is NOT floored silently: the excess is recorded and alerted.
  # The card is never canceled by a refund; the load flips to `refunded`
  # when it is empty and something was refunded.
  def self.apply_refund!(load, refund)
    card = load.gift_card
    alert = nil

    card.with_lock do
      card.reload
      load.reload
      return if Transaction.refunds.where("metadata->>'stripe_refund_id' = ?", refund.id).exists?

      Rails.logger.info "[Refund] Recording Stripe refund #{refund.id} for load #{load.id} / card #{card.id} (amount: #{refund.amount}, status: #{refund.status})"

      amount = refund.amount.to_i
      debit = [amount, load.remaining_cents].min
      over_refund = amount - debit

      # refunded_cents tracks money that left THIS load (keeps I2 intact); the
      # over-refund excess is recorded on the ledger row and alerted — it is
      # Papayal's realized loss, not card money.
      GiftCardLoad.where(id: load.id).update_all([
        "remaining_cents = remaining_cents - ?, refunded_cents = refunded_cents + ?, updated_at = ?", debit, debit, Time.current
      ])
      GiftCard.where(id: card.id).update_all(["remaining_balance = remaining_balance - ?, updated_at = ?", debit, Time.current])
      load.reload.sync_status!

      Transaction.create!(
        gift_card: card,
        gift_card_load: load,
        merchant: card.merchant,
        user: nil, # initiated externally (Stripe Dashboard) or via admin path
        amount: amount,
        currency: refund.currency&.upcase || load.currency,
        txn_type: :refund,
        status: :succeeded,
        processor_ref: refund.id,
        metadata: {
          stripe_refund_id: refund.id,
          stripe_charge_id: refund.try(:charge),
          gift_card_load_id: load.id,
          reason: refund.reason,
          refund_status_at_apply: refund.status,
          debited_cents: debit,
          over_refund_cents: over_refund,
          refunded_at: Time.current.iso8601,
          source: "stripe_webhook"
        }.compact
      )

      alert = over_refund if over_refund.positive?
    end

    if alert
      Rails.logger.error "[Refund] OVER-REFUND: refund #{refund.id} exceeded load #{load.id} remaining by #{alert} cents (already spent at a merchant)"
      AdminAlertMailer.over_refund(card.id, load.id, refund.id, alert, refund.currency&.upcase || load.currency).deliver_later
    end
  rescue ActiveRecord::RecordNotUnique
    # processor_ref unique index: another delivery recorded this refund
    # concurrently. Nothing to do.
    Rails.logger.warn "[Refund] Refund #{refund.id} already recorded concurrently; skipping"
  end

  # A refund we already debited did not go through (bank rejected it).
  # Restore the load (up to what it can hold), mark the ledger row failed,
  # alert admin: the buyer did NOT get their money back.
  def self.reverse_refund!(load, refund)
    card = load.gift_card
    reversed = false

    card.with_lock do
      card.reload
      load.reload

      txn = Transaction.refunds.succeeded
                       .where(gift_card_id: card.id)
                       .where("metadata->>'stripe_refund_id' = ?", refund.id)
                       .first
      unless txn
        Rails.logger.info "[Refund] No applied ledger row for failed refund #{refund.id}; nothing to reverse"
        return
      end

      # Undo exactly what apply_refund! did: refunded_cents drops by the
      # full amount, remaining_cents rises by what was actually debited
      # (never above the load's headroom).
      debited = txn.metadata["debited_cents"].nil? ? txn.amount.to_i : txn.metadata["debited_cents"].to_i
      restore = [debited, load.refunded_cents].min

      GiftCardLoad.where(id: load.id).update_all([
        "remaining_cents = remaining_cents + ?, refunded_cents = refunded_cents - ?, updated_at = ?",
        restore, restore, Time.current
      ])
      GiftCard.where(id: card.id).update_all(["remaining_balance = remaining_balance + ?, updated_at = ?", restore, Time.current])
      load.reload.sync_status!

      txn.update!(
        status: :failed,
        metadata: txn.metadata.merge(
          "refund_failed_at" => Time.current.iso8601,
          "refund_failure_reason" => refund.try(:failure_reason),
          "restored_cents" => restore
        )
      )
      reversed = true

      Rails.logger.warn "[Refund] Reversed failed refund #{refund.id} on load #{load.id}: restored #{restore} cents"
    end

    if reversed
      AdminAlertMailer.refund_failed(
        card.id,
        refund.id,
        refund.amount.to_i,
        refund.currency&.upcase || load.currency,
        refund.try(:failure_reason).to_s.presence
      ).deliver_later
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # payment_intent.payment_failed — a buyer tried to pay and was declined.
  # No money moved and no load exists; visibility only. Alert throttled to
  # one email per PaymentIntent per day (buyers retry many times).
  # ──────────────────────────────────────────────────────────────────────
  def self.handle_payment_intent_payment_failed(payment_intent)
    error = payment_intent.try(:last_payment_error)
    code = error.try(:code)
    decline_code = error.try(:decline_code)
    metadata = payment_intent.metadata || {}

    Rails.logger.warn(
      "[PaymentFailed] PI #{payment_intent.id} amount=#{payment_intent.amount} " \
      "code=#{code.inspect} decline_code=#{decline_code.inspect} " \
      "sender_id=#{metadata['sender_id'].inspect} merchant_id=#{metadata['merchant_id'].inspect}"
    )

    PaymentFailure.record_attempt!(payment_intent)

    first_alert = Rails.cache.write(
      "stripe:payment_failed_alert:#{payment_intent.id}",
      true,
      unless_exist: true,
      expires_in: 24.hours
    )
    return unless first_alert

    AdminAlertMailer.payment_failed(
      payment_intent.id,
      payment_intent.amount.to_i,
      payment_intent.currency&.upcase || "USD",
      code.to_s.presence,
      decline_code.to_s.presence,
      metadata["sender_id"].to_s.presence,
      metadata["merchant_id"].to_s.presence
    ).deliver_later
  rescue => e
    Rails.logger.error "[PaymentFailed] Handler error for #{payment_intent.try(:id)}: #{e.class} - #{e.message}"
  end

  # ──────────────────────────────────────────────────────────────────────
  # Disputes are per LOAD (§5.8, D4). An open dispute takes only that
  # load's remaining cents out of `spendable_cents`; every other load stays
  # spendable and the card keeps accepting loads from other buyers. The
  # disputing BUYER is blocked from new purchases while it is open.
  # ──────────────────────────────────────────────────────────────────────
  def self.handle_charge_dispute_created(dispute)
    load = GiftCardLoad.for_payment_intent(dispute.payment_intent)
    unless load
      Rails.logger.warn "[Dispute] No load found for dispute #{dispute.id} (PI: #{dispute.payment_intent})"
      return
    end

    card = load.gift_card
    recorded = false
    card.with_lock do
      card.reload
      load.reload
      # Idempotent: the same dispute id, or any open dispute, is already recorded.
      break if load.dispute_id == dispute.id || load.dispute_open?

      Rails.logger.warn "⚠️ Dispute created on load #{load.id} (card #{card.id}): reason=#{dispute.reason} amount=#{dispute.amount}"
      load.update!(disputed_at: Time.current, dispute_id: dispute.id, dispute_outcome: nil)
      User.where(id: load.sender_id).update_all(["dispute_open_count = dispute_open_count + 1, updated_at = ?", Time.current]) if load.sender_id
      recorded = true
    end
    return unless recorded

    AdminAlertMailer.dispute_created(card.id, dispute.id).deliver_later
    # §5.8: the recipient learns that one reload is on hold, not the card.
    Messaging::LoadEventPusher.dispute_opened(load)
  rescue => e
    Rails.logger.error "💥 charge.dispute.created handler error: #{e.class} - #{e.message}"
    raise
  end

  # won  → funds return to spendable; buyer unblocked.
  # lost → write off THAT load's remaining cents only (idempotent on
  #        `dispute_<id>`); buyer's lost count goes up; two lost disputes
  #        block the buyer from purchasing until an admin lifts it.
  # The card is never canceled automatically.
  def self.handle_charge_dispute_closed(dispute)
    load = GiftCardLoad.for_payment_intent(dispute.payment_intent)
    return unless load

    card = load.gift_card
    Rails.logger.info "[Dispute] Closed on load #{load.id} (card #{card.id}): status=#{dispute.status}"

    case dispute.status
    when "won"
      resolve_dispute_won!(load, dispute)
    when "lost"
      write_off_lost_dispute!(load, dispute)
    end

    AdminAlertMailer.dispute_closed(card.id, dispute.id, dispute.status).deliver_later
  rescue => e
    Rails.logger.error "💥 charge.dispute.closed handler error: #{e.class} - #{e.message}"
    raise
  end

  def self.resolve_dispute_won!(load, dispute)
    card = load.gift_card
    card.with_lock do
      load.reload
      break unless load.dispute_open?

      load.update!(dispute_outcome: "won", dispute_id: load.dispute_id || dispute.id)
      decrement_open_disputes!(load.sender_id)
    end
  end

  def self.write_off_lost_dispute!(load, dispute)
    card = load.gift_card
    blocked_buyer = nil

    card.with_lock do
      card.reload
      load.reload
      # Idempotent against re-delivery: keyed on the dispute id via processor_ref.
      break if Transaction.where(processor_ref: "dispute_#{dispute.id}").exists?

      written = load.remaining_cents
      was_open = load.dispute_open?

      GiftCardLoad.where(id: load.id).update_all([
        "remaining_cents = 0, written_off_cents = written_off_cents + ?, updated_at = ?", written, Time.current
      ])
      GiftCard.where(id: card.id).update_all(["remaining_balance = remaining_balance - ?, updated_at = ?", written, Time.current])
      load.reload
      load.update!(dispute_outcome: "lost", dispute_id: load.dispute_id || dispute.id, disputed_at: load.disputed_at || Time.current)

      Transaction.create!(
        gift_card: card,
        gift_card_load: load,
        merchant: card.merchant,
        user: nil,
        amount: written, # adjustment allows zero (already-drained load)
        currency: load.currency,
        txn_type: :adjustment,
        status: :succeeded,
        processor_ref: "dispute_#{dispute.id}",
        metadata: {
          stripe_dispute_id: dispute.id,
          gift_card_load_id: load.id,
          source: "dispute_lost",
          previous_remaining_cents: written,
          # Papayal's realized loss: what the buyer's disputed money already bought.
          spent_before_dispute_cents: load.amount_cents - written - load.refunded_cents,
          written_off_at: Time.current.iso8601
        }
      )

      if load.sender_id
        decrement_open_disputes!(load.sender_id) if was_open
        User.where(id: load.sender_id).update_all(["dispute_lost_count = dispute_lost_count + 1, updated_at = ?", Time.current])
        buyer = User.find_by(id: load.sender_id)
        if buyer && buyer.dispute_lost_count >= 2 && buyer.purchases_blocked_at.nil?
          buyer.update_columns(purchases_blocked_at: Time.current)
          blocked_buyer = buyer
        end
      end

      Rails.logger.warn "[Dispute] LOST — wrote off #{written} cents on load #{load.id} (card #{card.id} stays #{card.status})"
    end

    AdminAlertMailer.buyer_purchases_blocked(blocked_buyer.id, dispute.id).deliver_later if blocked_buyer
  end

  def self.decrement_open_disputes!(user_id)
    return unless user_id

    User.where(id: user_id).update_all(["dispute_open_count = GREATEST(dispute_open_count - 1, 0), updated_at = ?", Time.current])
  end
end
