module Refunds
  # Type B refund (§5.7): real Stripe refund to the original payer of ONE
  # load, for that load's unredeemed, not-yet-refunded part. Used by the
  # admin panel for support cases and the 72 h buyer withdrawal (D11).
  #
  # NOT to be confused with Refunds::Issue (Type A — reverses a merchant
  # capture, no money moves at Stripe).
  #
  # Idempotent at two levels: a fixed Stripe idempotency key per
  # (load, amount, actor), and the refund.* webhooks de-duping on
  # stripe_refund_id when they reconcile the internal ledger.
  class IssueStripeRefund
    class Error < StandardError; end
    class MissingPaymentIntent < Error; end
    class InvalidAmount < Error; end
    class AlreadyFullyRefunded < Error; end
    class ExceedsRefundableBalance < Error; end
    class LoadDisputed < Error; end

    def self.call(...)
      new(...).call
    end

    def initialize(load:, amount_cents:, reason:, actor:)
      @load = load
      @amount_cents = amount_cents.to_i
      @reason = reason.to_s.strip.presence
      @actor = actor
    end

    def call
      raise MissingPaymentIntent if @load.payment_intent_id.blank?
      raise InvalidAmount if @amount_cents <= 0

      card = @load.gift_card
      # Hold the card lock through validation AND the Stripe call (§6.6):
      # redemptions lock the same row, so the refundable part cannot be
      # spent at a register between the cap check and the money leaving.
      card.with_lock do
        @load.reload
        raise LoadDisputed, "load #{@load.id} has an open dispute" if @load.dispute_open?
        raise AlreadyFullyRefunded if @load.status_canceled? || @load.refundable_cents.zero?

        if @amount_cents > @load.refundable_cents
          raise ExceedsRefundableBalance,
                "Requested #{@amount_cents} exceeds refundable #{@load.refundable_cents} for load=#{@load.id} (card=#{card.id})"
        end

        create_stripe_refund(card)
      end
    end

    private

    def create_stripe_refund(card)
      idem_key = "refund:load#{@load.id}:#{@amount_cents}:#{@actor&.id}"

      refund = Stripe::Refund.create(
        {
          payment_intent: @load.payment_intent_id,
          amount: @amount_cents,
          reason: stripe_reason,
          metadata: {
            gift_card_id: card.id.to_s,
            gift_card_load_id: @load.id.to_s,
            admin_user_id: @actor&.id.to_s,
            internal_reason: @reason.to_s
          }.compact
        },
        { idempotency_key: idem_key }
      )

      Rails.logger.info(
        "[StripeRefund] Created refund #{refund.id} for load=#{@load.id} card=#{card.id} " \
        "amount_cents=#{@amount_cents} actor=#{@actor&.id} reason=#{@reason.inspect}"
      )

      # Internal balance reconciliation is performed by the refund.* webhook
      # (StripeWebhooks.apply_refund!) to keep a single code path.
      refund
    end

    def stripe_reason
      case @reason.to_s.downcase
      when /fraud/, /unauthorized/, /stolen/ then "fraudulent"
      when /duplicate/ then "duplicate"
      else "requested_by_customer"
      end
    end
  end
end
