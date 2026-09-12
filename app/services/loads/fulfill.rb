# Webhook fulfilment of `payment_intent.succeeded` (§5.2): every succeeded
# payment becomes ONE load on the recipient's ONE card at that merchant.
#
# The buyer has been charged at this point, so there are only two valid
# outcomes: a load exists, or the buyer gets their money back. Permanent
# failures raise StripeWebhooks::UnfulfillablePaymentError (caught by the
# webhook, which auto-refunds); transient errors re-raise so Stripe retries.
module Loads
  class Fulfill
    UnfulfillablePaymentError = StripeWebhooks::UnfulfillablePaymentError

    def self.call(payment_intent)
      new(payment_intent).call
    end

    def initialize(payment_intent)
      @payment_intent = payment_intent
      @metadata = payment_intent.metadata || {}
    end

    # @return [GiftCardLoad, nil] the load created (nil when this delivery
    #   was a duplicate and another delivery already fulfilled the payment)
    def call
      Rails.logger.info "💳 Payment intent succeeded: #{payment_intent.id} with metadata: #{metadata.inspect}"

      # 2. Idempotency first: a replay must never re-validate a payment that
      #    is already money on a card.
      if (existing = GiftCardLoad.for_payment_intent(payment_intent.id))
        Rails.logger.warn "⚠️ Load already exists for payment intent #{payment_intent.id} (load #{existing.id}); re-checking notification"
        enqueue_notification(existing.gift_card_id) unless notified?(existing)
        return nil
      end

      # 1. Validate merchant / sender / recipient / face value.
      merchant = resolve_merchant!
      sender = resolve_sender!
      recipient = resolve_recipient!(sender)
      subtotal_cents, buyer_fee_cents = face_value

      # 3. One card per (recipient, merchant). Canceled/frozen cards refuse loads.
      card = GiftCard.find_or_create_for!(recipient: recipient, merchant: merchant, first_sender: sender)
      if card.canceled?
        raise UnfulfillablePaymentError.new("card_canceled", "Card #{card.id} is canceled; refusing load for payment intent #{payment_intent.id}")
      end
      if card.frozen_by_admin?
        raise UnfulfillablePaymentError.new("card_frozen", "Card #{card.id} is frozen by an admin; refusing load for payment intent #{payment_intent.id}")
      end

      # 4. Caps re-check (TOCTOU with checkout).
      begin
        Loads::CapChecker.check!(buyer: sender, recipient: recipient, merchant: merchant, amount_cents: subtotal_cents)
      rescue Loads::CapChecker::CapExceeded => e
        raise UnfulfillablePaymentError.new("cap_exceeded:#{e.code}", "#{e.message} for payment intent #{payment_intent.id}")
      end

      # 5. Radar + processing cost live on the charge.
      charge = retrieve_charge
      risk = extract_risk_assessment(charge)

      # 6. Credit the load under the card lock.
      load = nil
      card.with_lock do
        card.reload
        begin
          load = card.loads.create!(
            sender: sender,
            source: :stripe,
            payment_intent_id: payment_intent.id,
            amount_cents: subtotal_cents,
            remaining_cents: subtotal_cents,
            fee_cents: buyer_fee_cents,
            currency: payment_intent.currency&.upcase || card.currency,
            note: metadata["recipient_note"].presence,
            risk_score: risk[:score],
            risk_level: risk[:level],
            held_until: risk[:hold_until]
          )
        rescue ActiveRecord::RecordInvalid => e
          if e.record.errors.of_kind?(:payment_intent_id, :taken)
            Rails.logger.warn "⚠️ Load already created concurrently for payment intent #{payment_intent.id} (validation)"
            return nil
          end

          raise UnfulfillablePaymentError.new("load_invalid", "Load validation failed for payment intent #{payment_intent.id}: #{e.message}")
        rescue ActiveRecord::RecordNotUnique
          Rails.logger.warn "⚠️ Load already created concurrently for payment intent #{payment_intent.id}"
          return nil
        end

        # Counters: arithmetic under the lock (§6.7). loads_count is the
        # counter cache on the association — never bumped by hand.
        GiftCard.where(id: card.id).update_all([
          "remaining_balance = remaining_balance + ?, total_loaded_cents = total_loaded_cents + ?, " \
          "amount = COALESCE(amount, 0) + ?, last_loaded_at = ?, updated_at = ?",
          subtotal_cents, subtotal_cents, subtotal_cents, load.created_at, Time.current
        ])

        card.transactions.create!(
          gift_card_load: load,
          amount: subtotal_cents,
          txn_type: :purchase,
          status: :succeeded,
          processor_ref: payment_intent.id,
          merchant: merchant,
          user: sender,
          currency: load.currency,
          metadata: {
            stripe_payment_intent_id: payment_intent.id,
            gift_card_load_id: load.id,
            customer_email: payment_intent.receipt_email,
            subtotal_cents: subtotal_cents,
            fee_cents: buyer_fee_cents,
            total_paid_cents: payment_intent.amount
          }.merge(extract_processing_cost(charge))
        )
      end
      card.reload

      # 7. Notifications (card-level until Phase 3b moves them per load).
      if load.held?
        Rails.logger.warn "🛡️ Load #{load.id} on card #{card.id} placed on security hold until #{load.held_until.iso8601} (risk_score=#{risk[:score]}, level=#{risk[:level]})"
        GiftCardHoldMailer.held(card.id).deliver_later
      end

      begin
        PurchaseConfirmationMailer.receipt(card.id).deliver_later
      rescue => e
        Rails.logger.error "✉️ Failed to enqueue purchase receipt for card #{card.id}: #{e.class} - #{e.message}"
        Sentry.capture_exception(e) if defined?(Sentry)
      end

      enqueue_notification(card.id)

      Rails.logger.info "✅ Fulfilled payment intent #{payment_intent.id}: load #{load.id} (#{subtotal_cents} #{load.currency}) on card #{card.id} for #{recipient.email}; balance now #{card.remaining_balance}"
      load
    rescue UnfulfillablePaymentError
      raise
    rescue => e
      Rails.logger.error "💥 Error fulfilling payment_intent.succeeded: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.first(15).join("\n")
      raise
    end

    private

    attr_reader :payment_intent, :metadata

    def resolve_merchant!
      merchant_id = metadata["merchant_id"].to_s.strip
      unless merchant_id.match?(/\A\d+\z/)
        raise UnfulfillablePaymentError.new("merchant_invalid", "Missing or malformed merchant_id #{metadata['merchant_id'].inspect} for payment intent #{payment_intent.id}")
      end

      merchant = Merchant.find_by(id: merchant_id)
      raise UnfulfillablePaymentError.new("merchant_invalid", "Unknown merchant_id #{merchant_id} for payment intent #{payment_intent.id}") unless merchant
      unless merchant.active?
        raise UnfulfillablePaymentError.new("merchant_inactive", "Merchant #{merchant.id} is #{merchant.status} for payment intent #{payment_intent.id}")
      end

      merchant
    end

    def resolve_sender!
      sender = User.find_by(id: metadata["sender_id"])
      raise UnfulfillablePaymentError.new("sender_missing", "No sender found for payment intent #{payment_intent.id}") unless sender

      sender
    end

    # Self-reload (recipient_user_id == sender) needs no lookup or shell user.
    def resolve_recipient!(sender)
      if metadata["recipient_user_id"].present? && metadata["recipient_user_id"].to_s == sender.id.to_s
        return sender
      end

      recipient = self.class.find_or_create_recipient(metadata)
      raise UnfulfillablePaymentError.new("recipient_missing", "Failed to find or create recipient for payment intent #{payment_intent.id}") unless recipient

      recipient
    end

    # Face value = what the buyer chose (metadata written at checkout). The
    # PI amount additionally includes the buyer service fee. Distrust
    # nonsensical metadata (zero/negative or above the charge).
    def face_value
      subtotal = metadata["subtotal_cents"].presence.to_i
      subtotal = payment_intent.amount if subtotal <= 0 || subtotal > payment_intent.amount
      [subtotal, payment_intent.amount - subtotal]
    end

    def notified?(load)
      card = load.gift_card
      load.sent_via_email? || load.sent_via_sms? || load.sent_via_whatsapp? || load.sent_via_push? ||
        card.sent_via_email? || card.sent_via_sms? || card.sent_via_whatsapp? || card.sent_via_push?
    end

    # In production never block the webhook on a sync send; in development
    # and test fall back to perform_now when Sidekiq/Redis is unavailable.
    def enqueue_notification(gift_card_id)
      NotificationJob.perform_later(gift_card_id)
      Rails.logger.info "📤 Enqueued notification job for gift card #{gift_card_id} (async)"
    rescue NoMethodError, Redis::CannotConnectError => e
      if Rails.env.production?
        Rails.logger.error "❌ Sidekiq/Redis unavailable (#{e.class}); notification not sent for gift_card_id=#{gift_card_id}."
      else
        Rails.logger.warn "⚠️ Sidekiq not available (#{e.class}), sending notification synchronously"
        NotificationJob.perform_now(gift_card_id)
      end
    rescue => e
      Rails.logger.error "❌ Failed to enqueue/send notification: #{e.message}"
    end

    # ── Recipient resolution (shared with checkout) ─────────────────────

    # phone → email → new pending shell user. Returns nil when neither
    # contact channel is present. Exposed for checkout's prospective lookup
    # via `find_recipient` (never creates).
    def self.find_or_create_recipient(metadata)
      found = find_recipient(metadata)
      return found if found

      phone = metadata["recipient_phone"].presence
      email = metadata["recipient_email"].presence&.downcase
      if email.blank? && phone.blank?
        Rails.logger.error "❌ Cannot create recipient: both email and phone are blank"
        return nil
      end

      recipient_name = metadata["recipient_name"].presence
      name_parts = recipient_name.to_s.split(/\s+/, 2)
      recipient = User.create!(
        name: recipient_name,
        first_name: name_parts[0].presence,
        last_name: name_parts[1].presence,
        email: email || User.placeholder_email_for_phone(phone),
        phone: phone,
        password: SecureRandom.hex(32),
        role: :user,
        pending_recipient: true,
        skip_national_id_validation: true
      )
      Rails.logger.info "✅ Created pending recipient: user_id=#{recipient.id} email=#{recipient.email} phone=#{recipient.phone || '(none)'}"
      recipient
    end

    def self.find_recipient(metadata)
      phone = metadata["recipient_phone"].presence
      email = metadata["recipient_email"].presence&.downcase
      (phone.present? && User.find_by(phone: phone)) || (email.present? && User.find_by(email: email)) || nil
    end

    # ── Stripe charge helpers ───────────────────────────────────────────

    # `latest_charge` is a charge id string in webhook payloads (an expanded
    # Stripe::Charge when the caller requested expansion). balance_transaction
    # is expanded so the processing cost is available without a second call.
    def retrieve_charge
      charge = payment_intent.try(:latest_charge)
      charge = Stripe::Charge.retrieve({ id: charge, expand: ["balance_transaction"] }) if charge.is_a?(String)
      charge
    rescue => e
      Rails.logger.warn "[Stripe] Failed to retrieve charge for PI #{payment_intent.id}: #{e.class} #{e.message}"
      nil
    end

    # Radar risk → per-load hold when score >= GiftCard::RISK_HOLD_THRESHOLD.
    # Missing charge/outcome (test charges) = zero risk.
    def extract_risk_assessment(charge)
      if charge.nil?
        Rails.logger.warn "[Radar] No latest_charge on PI #{payment_intent.id}; treating as zero risk"
        return { score: 0, level: nil, hold_until: nil }
      end

      outcome = charge.try(:outcome)
      score = outcome.try(:risk_score).to_i
      level = outcome.try(:risk_level).to_s.presence
      hold_until = (Time.current + GiftCard::RISK_HOLD_DURATION if score >= GiftCard::RISK_HOLD_THRESHOLD)
      { score: score, level: level, hold_until: hold_until }
    rescue => e
      Rails.logger.warn "[Radar] Failed to extract risk assessment from PI #{payment_intent.id}: #{e.class} #{e.message}"
      { score: 0, level: nil, hold_until: nil }
    end

    def extract_processing_cost(charge)
      return {} if charge.nil?

      balance_txn = charge.try(:balance_transaction)
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
  end
end
