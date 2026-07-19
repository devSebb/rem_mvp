class StripeWebhooks
  # Raised when a succeeded payment can never be fulfilled as a gift card
  # (bad/suspended merchant, missing sender/recipient, limit exceeded,
  # invalid card data). These are PERMANENT failures: retrying the webhook
  # will not fix them, so the money must go back to the buyer instead of
  # being stranded. Transient errors (DB/Redis down) are deliberately NOT
  # mapped to this class — they re-raise so Stripe retries delivery.
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

  private

  # The buyer has been charged at this point, so there are only two valid
  # outcomes: a gift card exists, or the buyer gets their money back.
  # Permanent fulfillment failures auto-refund; transient errors re-raise
  # so Stripe retries the delivery.
  def self.handle_payment_intent_succeeded(payment_intent)
    fulfill_payment_intent!(payment_intent)
    mark_payment_failures_resolved(payment_intent)
  rescue UnfulfillablePaymentError => e
    refund_unfulfillable_payment(payment_intent, e)
  end

  # A PI that failed earlier and now succeeded means the buyer retried and
  # got through — close the decline record so the admin list shows only
  # genuinely lost sales. Never lets bookkeeping break fulfillment.
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
    # Swallow the error from here: the webhook returns 200 so Stripe stops
    # retrying — the money is back with the buyer, nothing left to retry.
    # If RefundOrphanedPayment itself raised (Stripe API down), we let that
    # propagate instead: Stripe re-delivers and the refund is re-attempted.
  rescue Refunds::RefundOrphanedPayment::GiftCardExists
    # A concurrent delivery created the card after our check — the payment
    # was actually fulfilled, so there is nothing to refund.
    Rails.logger.warn "⚠️ Gift card appeared for #{payment_intent.id} while handling failure; skipping refund"
  end

  def self.fulfill_payment_intent!(payment_intent)
    metadata = payment_intent.metadata || {}
    Rails.logger.info "💳 Payment intent succeeded: #{payment_intent.id} with metadata: #{metadata.inspect}"

    merchant_id_raw = metadata["merchant_id"]
    merchant_id = merchant_id_raw.to_s.strip

    if merchant_id.blank? || !merchant_id.match?(/\A\d+\z/)
      raise UnfulfillablePaymentError.new(
        "merchant_invalid",
        "Missing or malformed merchant_id #{merchant_id_raw.inspect} for payment intent #{payment_intent.id}"
      )
    end

    merchant = Merchant.find_by(id: merchant_id)
    unless merchant
      raise UnfulfillablePaymentError.new(
        "merchant_invalid",
        "Unknown merchant_id #{merchant_id} for payment intent #{payment_intent.id}"
      )
    end

    # Checkout validated active? but the merchant can be suspended between
    # checkout and webhook delivery; a card for a suspended merchant would
    # be unredeemable (dead money).
    unless merchant.active?
      raise UnfulfillablePaymentError.new(
        "merchant_inactive",
        "Merchant #{merchant.id} is #{merchant.status} for payment intent #{payment_intent.id}"
      )
    end

    # Find sender user
    sender = User.find_by(id: metadata['sender_id'])
    unless sender
      raise UnfulfillablePaymentError.new(
        "sender_missing",
        "No sender found for payment intent #{payment_intent.id}"
      )
    end
    Rails.logger.info "✅ Found sender: #{sender.email} (ID: #{sender.id})"

    # Find or create recipient user
    recipient = find_or_create_recipient(metadata)
    unless recipient
      raise UnfulfillablePaymentError.new(
        "recipient_missing",
        "Failed to find or create recipient for payment intent #{payment_intent.id}"
      )
    end
    Rails.logger.info "✅ Found/created recipient: #{recipient.email} (ID: #{recipient.id})"

    Rails.logger.info "✅ Merchant: #{merchant.store_name}"

    # Face value = what the buyer chose (metadata written at checkout). The
    # PI amount additionally includes the buyer service fee. Legacy PIs
    # without the metadata predate fees: face value == charged amount.
    # Distrust nonsensical metadata (zero/negative or above the charge).
    subtotal_cents = metadata["subtotal_cents"].presence.to_i
    if subtotal_cents <= 0 || subtotal_cents > payment_intent.amount
      subtotal_cents = payment_intent.amount
    end
    buyer_fee_cents = payment_intent.amount - subtotal_cents

    # Validate amount (defense in depth - should already be validated at checkout)
    if subtotal_cents > GiftCard::MAX_AMOUNT_CENTS
      raise UnfulfillablePaymentError.new(
        "amount_exceeds_max",
        "Amount #{subtotal_cents} exceeds maximum #{GiftCard::MAX_AMOUNT_CENTS} for payment intent #{payment_intent.id}"
      )
    end

    # Re-check the purchase limit (checkout already gates it, but concurrent
    # checkouts can all pass that check before any card exists — TOCTOU).
    # The buyer has already paid here, so exceeding the limit must refund
    # the excess purchase rather than strand the money.
    limit_check = GiftCardPurchaseLimiter.can_purchase?(user: sender)
    unless limit_check[:allowed]
      raise UnfulfillablePaymentError.new(
        "purchase_limit_exceeded",
        "Purchase limit exceeded for user #{sender.id} (#{limit_check[:count]}/#{limit_check[:limit]} in 24h) on payment intent #{payment_intent.id}"
      )
    end

    # Check if gift card already exists for this payment intent (idempotency)
    existing_gift_card = GiftCard.find_by(payment_intent_id: payment_intent.id)
    if existing_gift_card
      Rails.logger.warn "⚠️ Gift card already exists for payment intent #{payment_intent.id} (ID: #{existing_gift_card.id})"
      Rails.logger.info "   Skipping creation, but will attempt to send notification if not sent yet"
      
      # Try to send notification if it wasn't sent yet
      if !existing_gift_card.sent_via_email && !existing_gift_card.sent_via_sms && !existing_gift_card.sent_via_whatsapp
        raw_code = existing_gift_card.generate_code!
        enqueue_notification(existing_gift_card.id, raw_code)
      end
      
      return
    end

    # Retrieve the charge once: Radar risk assessment (security holds) and
    # the balance transaction (actual Stripe processing cost) both live on it.
    charge = retrieve_charge(payment_intent)

    # Read Stripe's Radar risk assessment so we can apply a security hold
    # on elevated-risk charges. score >= 75 is blocked by Stripe by default
    # so we should only see normal (0-64) or elevated (65-74) charges here.
    risk = extract_risk_assessment(payment_intent, charge)

    # Create gift card safely (no expiration - gift cards never expire)
    begin
      gift_card = GiftCard.create!(
        sender: sender,
        recipient: recipient,
        merchant: merchant,
        amount: subtotal_cents, # face value in cents (charged total minus buyer fee)
        currency: payment_intent.currency&.upcase || "USD",
        payment_intent_id: payment_intent.id,
        expires_at: nil, # Gift cards never expire
        note: metadata['recipient_note'].presence,
        risk_score: risk[:score],
        risk_level: risk[:level],
        held_until: risk[:hold_until]
      )
    rescue ActiveRecord::RecordInvalid => e
      # Validation failures won't heal on retry — refund instead of stranding
      raise UnfulfillablePaymentError.new(
        "gift_card_invalid",
        "Gift card validation failed for payment intent #{payment_intent.id}: #{e.message}"
      )
    rescue ActiveRecord::RecordNotUnique
      # Concurrent delivery won the unique payment_intent_id race — the card
      # exists, so this delivery has nothing left to do.
      Rails.logger.warn "⚠️ Gift card already created concurrently for payment intent #{payment_intent.id}"
      return
    end

    if gift_card.held?
      Rails.logger.warn(
        "🛡️ Gift card #{gift_card.id} placed on security hold until " \
        "#{gift_card.held_until.iso8601} (risk_score=#{risk[:score]}, level=#{risk[:level]})"
      )
      GiftCardHoldMailer.held(gift_card.id).deliver_later
    end

    # Generate code after saving
    raw_code = gift_card.generate_code!
    Rails.logger.info "✅ Generated gift card code for gift card #{gift_card.id}"

    # Create purchase transaction only if association exists
    if gift_card.respond_to?(:transactions)
      gift_card.transactions.create!(
        amount: gift_card.amount,
        txn_type: :purchase,
        status: :succeeded,
        processor_ref: payment_intent.id,
        merchant: merchant,
        user: sender,
        currency: gift_card.currency,
        metadata: {
          stripe_payment_intent_id: payment_intent.id,
          customer_email: payment_intent.receipt_email,
          subtotal_cents: subtotal_cents,
          fee_cents: buyer_fee_cents,
          total_paid_cents: payment_intent.amount
        }.merge(extract_processing_cost(charge))
      )
      Rails.logger.info "✅ Created purchase transaction for gift card #{gift_card.id}"
    else
      Rails.logger.warn "⚠️ GiftCard #{gift_card.id} has no transactions association"
    end

    # Buyer receipt. Best-effort: a mail failure must never fail the webhook
    # (that would trigger a Stripe retry / auto-refund on an already-fulfilled
    # purchase). The recipient's delivery email is enqueued separately below.
    begin
      PurchaseConfirmationMailer.receipt(gift_card.id).deliver_later
    rescue => e
      Rails.logger.error "✉️ Failed to enqueue purchase receipt for gift card #{gift_card.id}: #{e.class} - #{e.message}"
      Sentry.capture_exception(e) if defined?(Sentry)
    end

    enqueue_notification(gift_card.id, raw_code)

    Rails.logger.info "✅ Successfully created gift card #{gift_card.id} for payment intent #{payment_intent.id}"
    Rails.logger.info "   Recipient: #{recipient.email}, Amount: #{gift_card.currency} #{gift_card.amount / 100.0}"
  rescue UnfulfillablePaymentError
    raise # handled by handle_payment_intent_succeeded (auto-refund)
  rescue => e
    # Transient failure (DB down, etc.): re-raise so the webhook 500s and
    # Stripe retries the delivery.
    Rails.logger.error "💥 Error handling payment_intent.succeeded: #{e.class} - #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise
  end

  # Enqueue notification job. In production we never block the webhook on sync send;
  # in development/test we fall back to perform_now if Sidekiq/Redis is unavailable.
  #
  # Only the gift card id is enqueued — the raw bearer code must never be
  # serialized into Redis job payloads (Messaging::Notifier derives it from
  # the encrypted column). The second arg is accepted so existing call
  # sites keep working, but it is deliberately dropped.
  def self.enqueue_notification(gift_card_id, _legacy_raw_code = nil)
    NotificationJob.perform_later(gift_card_id)
    Rails.logger.info "📤 Enqueued notification job for gift card #{gift_card_id} (async)"
  rescue NoMethodError, Redis::CannotConnectError => e
    if Rails.env.production?
      Rails.logger.error "❌ Sidekiq/Redis unavailable (#{e.class}); notification not sent for gift_card_id=#{gift_card_id}. Fix Redis and retry manually if needed."
      # Do not block webhook; notification can be retried via support or cron
    else
      Rails.logger.warn "⚠️ Sidekiq not available (#{e.class}), sending notification synchronously"
      NotificationJob.perform_now(gift_card_id)
      Rails.logger.info "📤 Sent notification for gift card #{gift_card_id} (sync)"
    end
  rescue => e
    Rails.logger.error "❌ Failed to enqueue/send notification: #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n")
  end

  def self.find_or_create_recipient(metadata)
    phone = metadata['recipient_phone'].presence
    email = metadata['recipient_email'].presence&.downcase

    Rails.logger.info "🔍 Looking for recipient with email: #{email || '(none)'}, phone: #{phone || '(none)'}"

    # Try to find existing user by phone first, then email.
    if phone.present?
      recipient = User.find_by(phone: phone)
      if recipient
        Rails.logger.info "✅ Found recipient by phone: user_id=#{recipient.id} pending=#{recipient.pending?}"
        return recipient
      end
    end

    if email.present?
      recipient = User.find_by(email: email)
      if recipient
        Rails.logger.info "✅ Found recipient by email: user_id=#{recipient.id} pending=#{recipient.pending?}"
        return recipient
      end
    end

    # Refuse to create without at least one real contact channel.
    if email.blank? && phone.blank?
      Rails.logger.error "❌ Cannot create recipient: both email and phone are blank"
      return nil
    end

    # Create a pending recipient. claimed_at: nil signals "not signed up yet";
    # validations on first_name/last_name/phone are skipped while pending.
    # If only phone was provided, we synthesize a placeholder email so Devise
    # :validatable (which requires email format) is satisfied. The placeholder
    # is detected by Notifier and skipped for real email delivery.
    recipient_name = metadata['recipient_name'].presence
    name_parts = recipient_name.to_s.split(/\s+/, 2)
    first_name = name_parts[0].presence
    last_name = name_parts[1].presence
    effective_email = email || User.placeholder_email_for_phone(phone)

    recipient = User.create!(
      name: recipient_name,
      first_name: first_name,
      last_name: last_name,
      email: effective_email,
      phone: phone,
      password: SecureRandom.hex(32),
      role: :user,
      pending_recipient: true,
      skip_national_id_validation: true
    )
    Rails.logger.info "✅ Created pending recipient: user_id=#{recipient.id} email=#{recipient.email} phone=#{recipient.phone || '(none)'}"
    recipient
  end

  # ──────────────────────────────────────────────────────────────────────
  # Risk-scored security hold
  # ──────────────────────────────────────────────────────────────────────

  # Resolve the charge attached to the PaymentIntent.
  #
  # Current Stripe API versions expose the charge via `latest_charge` — a
  # charge ID string in webhook payloads (an expanded Stripe::Charge when
  # the caller requested expansion). NOTE: `payment_intent.charges` no
  # longer exists; reading it silently zeroed every risk score.
  #
  # balance_transaction is expanded so the processing cost is available
  # without a second API round-trip. Best-effort: returns nil on failure.
  def self.retrieve_charge(payment_intent)
    charge = payment_intent.try(:latest_charge)
    charge = Stripe::Charge.retrieve({ id: charge, expand: ["balance_transaction"] }) if charge.is_a?(String)
    charge
  rescue => e
    Rails.logger.warn "[Stripe] Failed to retrieve charge for PI #{payment_intent.id}: #{e.class} #{e.message}"
    nil
  end

  # Pull Stripe Radar's risk assessment off the charge attached to the
  # PaymentIntent. Returns { score:, level:, hold_until: } with hold_until
  # set only when the score exceeds GiftCard::RISK_HOLD_THRESHOLD.
  #
  # Defensive: if the charge or outcome is missing (test charges without
  # Radar), treat as zero risk — better to release the card than block it
  # on stale metadata. `try` is used so absent attributes return nil
  # instead of raising NoMethodError and silently zeroing real scores.
  def self.extract_risk_assessment(payment_intent, charge)
    if charge.nil?
      Rails.logger.warn "[Radar] No latest_charge on PI #{payment_intent.id}; treating as zero risk"
      return { score: 0, level: nil, hold_until: nil }
    end

    outcome = charge.try(:outcome)
    score = outcome.try(:risk_score).to_i
    level = outcome.try(:risk_level).to_s.presence

    hold_until = if score >= GiftCard::RISK_HOLD_THRESHOLD
      Time.current + GiftCard::RISK_HOLD_DURATION
    end

    { score: score, level: level, hold_until: hold_until }
  rescue => e
    Rails.logger.warn "[Radar] Failed to extract risk assessment from PI #{payment_intent.id}: #{e.class} #{e.message}"
    { score: 0, level: nil, hold_until: nil }
  end

  # Actual Stripe processing cost for this charge, read from the balance
  # transaction (expanded by retrieve_charge). Stored on the purchase ledger
  # row so per-transaction economics (fee charged vs. cost paid) are
  # queryable. Best-effort: any failure returns {} and never blocks fulfillment.
  def self.extract_processing_cost(charge)
    return {} if charge.nil?

    balance_txn = charge.try(:balance_transaction)
    # Without expansion this is just an id string; skip rather than fetch again.
    return {} if balance_txn.nil? || balance_txn.is_a?(String)

    {
      stripe_fee_cents: balance_txn.try(:fee),
      stripe_net_cents: balance_txn.try(:net),
      stripe_balance_transaction_id: balance_txn.try(:id)
    }.compact
  rescue => e
    Rails.logger.warn "[Fees] Failed to extract processing cost from charge #{charge.try(:id)}: #{e.class} #{e.message}"
    {}
  end

  # ──────────────────────────────────────────────────────────────────────
  # refund.created / refund.updated / refund.failed — reconcile internal
  # state with a Stripe-side refund. Triggered for refunds issued via the
  # Admin tool (Refunds::IssueStripeRefund) AND for refunds issued directly
  # in the Stripe Dashboard. These events carry the Refund object itself,
  # unlike charge.refunded whose payload stopped embedding the refunds
  # list on API versions >= 2022-11-15 (which silently broke the old
  # handler). Idempotent against re-delivery and against overlap with
  # charge.refunded: de-duped on stripe_refund_id metadata, backstopped by
  # the unique index on processor_ref.
  #
  # Also called by `rake stripe:reconcile_refunds` for backfill/repair.
  # ──────────────────────────────────────────────────────────────────────
  def self.handle_refund_event(refund)
    gift_card = find_gift_card_for_refund(refund)
    return unless gift_card

    case refund.status
    when "succeeded", "pending"
      # `pending` still debits: card refunds almost always settle, and if
      # this one doesn't, refund.failed arrives later and reverses it.
      apply_refund!(gift_card, refund)
    when "failed", "canceled"
      reverse_refund!(gift_card, refund)
    else
      Rails.logger.info "[Refund] Ignoring refund #{refund.id} with status #{refund.status.inspect}"
    end
  rescue => e
    Rails.logger.error "💥 refund event handler error: #{e.class} - #{e.message}"
    Rails.logger.error e.backtrace.first(10).join("\n")
    raise
  end

  # charge.refunded — defensive alias kept for older payloads and as a
  # second delivery channel. Modern payloads no longer embed the refunds
  # list, so when it's absent we fetch the refunds from the API and run
  # them through the same reconciliation as refund.* events (de-dupe makes
  # the overlap harmless).
  def self.handle_charge_refunded(charge)
    refunds = charge.try(:refunds).try(:data)
    refunds = Stripe::Refund.list(charge: charge.id).data if refunds.blank?

    Array(refunds).each { |refund| handle_refund_event(refund) }
  rescue => e
    Rails.logger.error "💥 charge.refunded handler error: #{e.class} - #{e.message}"
    Rails.logger.error e.backtrace.first(10).join("\n")
    raise
  end

  def self.find_gift_card_for_refund(refund)
    payment_intent_id = refund.try(:payment_intent)
    if payment_intent_id.blank?
      Rails.logger.warn "[Refund] Refund #{refund.id} has no payment_intent; skipping"
      return nil
    end

    gift_card = GiftCard.find_by(payment_intent_id: payment_intent_id)
    unless gift_card
      # Expected for orphaned-payment auto-refunds (no card was ever
      # created — that's the point of the refund).
      Rails.logger.warn "[Refund] No gift card found for refund #{refund.id} (PI: #{payment_intent_id})"
      return nil
    end

    gift_card
  end

  def self.apply_refund!(gift_card, refund)
    gift_card.with_lock do
      gift_card.reload
      return if Transaction.refunds.where("metadata->>'stripe_refund_id' = ?", refund.id).exists?

      Rails.logger.info "[Refund] Recording Stripe refund #{refund.id} for gift card #{gift_card.id} (amount: #{refund.amount}, status: #{refund.status})"

      # previous_status is stored so a later refund.failed can restore the
      # card exactly as it was before this refund canceled it.
      previous_status = gift_card.status

      # Decrement remaining_balance by the refund amount, floor at 0.
      # A full refund cancels the card; partial leaves it active with
      # the reduced balance.
      new_balance = [gift_card.remaining_balance.to_i - refund.amount.to_i, 0].max
      updates = { remaining_balance: new_balance }
      if refund.amount.to_i >= gift_card.amount.to_i || new_balance.zero?
        updates[:status] = :canceled
      end
      gift_card.update!(updates)

      Transaction.create!(
        gift_card: gift_card,
        merchant: gift_card.merchant,
        user: nil, # initiated externally (Stripe Dashboard) or via admin path
        amount: refund.amount,
        currency: refund.currency&.upcase || gift_card.currency,
        txn_type: :refund,
        status: :succeeded,
        processor_ref: refund.id,
        metadata: {
          stripe_refund_id: refund.id,
          stripe_charge_id: refund.try(:charge),
          reason: refund.reason,
          refund_status_at_apply: refund.status,
          previous_card_status: previous_status,
          refunded_at: Time.current.iso8601,
          source: "stripe_webhook"
        }
      )
    end
  rescue ActiveRecord::RecordNotUnique
    # processor_ref unique index: another delivery (refund.updated,
    # charge.refunded) recorded this refund concurrently. Nothing to do.
    Rails.logger.warn "[Refund] Refund #{refund.id} already recorded concurrently; skipping"
  end

  # A refund we already debited did not go through (bank rejected it —
  # rare, but real money). Restore the card to its pre-refund state, mark
  # the ledger row failed, and alert the admin: the buyer did NOT get
  # their money back, so support follow-up is needed.
  def self.reverse_refund!(gift_card, refund)
    reversed = false

    gift_card.with_lock do
      gift_card.reload

      txn = Transaction.refunds.succeeded
                       .where(gift_card_id: gift_card.id)
                       .where("metadata->>'stripe_refund_id' = ?", refund.id)
                       .first
      unless txn
        # Nothing was applied for this refund (or it was already reversed);
        # either way there is nothing to undo.
        Rails.logger.info "[Refund] No applied ledger row for failed refund #{refund.id}; nothing to reverse"
        return
      end

      restored_balance = [gift_card.remaining_balance.to_i + txn.amount.to_i, gift_card.amount.to_i].min
      updates = { remaining_balance: restored_balance }

      previous_status = txn.metadata["previous_card_status"].to_s
      if gift_card.canceled? && GiftCard.statuses.key?(previous_status)
        updates[:status] = previous_status
      end
      gift_card.update!(updates)

      txn.update!(
        status: :failed,
        metadata: txn.metadata.merge(
          "refund_failed_at" => Time.current.iso8601,
          "refund_failure_reason" => refund.try(:failure_reason)
        )
      )
      reversed = true

      Rails.logger.warn "[Refund] Reversed failed refund #{refund.id} on gift card #{gift_card.id}: balance restored to #{restored_balance}"
    end

    if reversed
      AdminAlertMailer.refund_failed(
        gift_card.id,
        refund.id,
        refund.amount.to_i,
        refund.currency&.upcase || gift_card.currency,
        refund.try(:failure_reason).to_s.presence
      ).deliver_later
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # payment_intent.payment_failed — a buyer tried to pay and was declined.
  # No money moved and no card exists; this is purely for visibility
  # (declines were previously invisible — lost sales nobody knew about).
  # Alert is throttled to one email per PaymentIntent per day: Stripe
  # emits one event per attempt and buyers often retry many times.
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
    # Visibility must never break payment processing or trigger Stripe
    # retries — log and move on.
    Rails.logger.error "[PaymentFailed] Handler error for #{payment_intent.try(:id)}: #{e.class} - #{e.message}"
  end

  # ──────────────────────────────────────────────────────────────────────
  # charge.dispute.created — chargeback filed. Block further redemption
  # and alert admin so they can decide whether to fight or accept.
  # ──────────────────────────────────────────────────────────────────────
  def self.handle_charge_dispute_created(dispute)
    payment_intent_id = dispute.payment_intent
    gift_card = GiftCard.find_by(payment_intent_id: payment_intent_id)
    unless gift_card
      Rails.logger.warn "[Dispute] No gift card found for dispute #{dispute.id} (PI: #{payment_intent_id})"
      return
    end

    return if gift_card.disputed? # already recorded; idempotent

    Rails.logger.warn "⚠️ Dispute created for gift card #{gift_card.id}: reason=#{dispute.reason} amount=#{dispute.amount}"

    gift_card.update!(disputed_at: Time.current)
    AdminAlertMailer.dispute_created(gift_card.id, dispute.id).deliver_later
  rescue => e
    Rails.logger.error "💥 charge.dispute.created handler error: #{e.class} - #{e.message}"
    raise
  end

  # ──────────────────────────────────────────────────────────────────────
  # charge.dispute.closed — outcome resolved. A LOST dispute means the
  # bank clawed the money back: the card must stop being redeemable, so
  # it is canceled and its remaining balance written off with an
  # adjustment ledger row. We don't auto-restore the card on a win (admin
  # reviews case-by-case — disputed_at stays set, which keeps redemption
  # blocked until an admin clears it deliberately).
  # ──────────────────────────────────────────────────────────────────────
  def self.handle_charge_dispute_closed(dispute)
    payment_intent_id = dispute.payment_intent
    gift_card = GiftCard.find_by(payment_intent_id: payment_intent_id)
    return unless gift_card

    Rails.logger.info "[Dispute] Closed for gift card #{gift_card.id}: status=#{dispute.status}"

    cancel_card_for_lost_dispute!(gift_card, dispute) if dispute.status == "lost"

    AdminAlertMailer.dispute_closed(gift_card.id, dispute.id, dispute.status).deliver_later
  rescue => e
    Rails.logger.error "💥 charge.dispute.closed handler error: #{e.class} - #{e.message}"
    raise
  end

  def self.cancel_card_for_lost_dispute!(gift_card, dispute)
    gift_card.with_lock do
      gift_card.reload
      # Idempotent against re-delivery: the write-off row is keyed on the
      # dispute id via processor_ref (unique index).
      return if Transaction.where(processor_ref: "dispute_#{dispute.id}").exists?

      written_off = gift_card.remaining_balance.to_i

      Transaction.create!(
        gift_card: gift_card,
        merchant: gift_card.merchant,
        user: nil,
        amount: written_off, # adjustment allows zero (already-drained card)
        currency: gift_card.currency,
        txn_type: :adjustment,
        status: :succeeded,
        processor_ref: "dispute_#{dispute.id}",
        metadata: {
          stripe_dispute_id: dispute.id,
          source: "dispute_lost",
          previous_card_status: gift_card.status,
          previous_remaining_balance: written_off,
          written_off_at: Time.current.iso8601
        }
      )

      gift_card.update!(status: :canceled, remaining_balance: 0)
      Rails.logger.warn "[Dispute] LOST — canceled gift card #{gift_card.id} and wrote off #{written_off} cents"
    end
  end
end
