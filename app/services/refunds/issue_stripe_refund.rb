module Refunds
  # Issues a real Stripe refund against the original PaymentIntent and
  # records the reconciliation transaction. Used by Admin::RefundsController
  # for buyer-initiated refund requests (Type B in the refund design).
  #
  # NOT to be confused with Refunds::Issue, which operates on a redemption
  # transaction (Type A — reverses a merchant capture, returns balance to
  # the gift card, no money moves at Stripe).
  #
  # Idempotent at two levels:
  #   - Stripe-side: passes idempotency_key so retried calls return the
  #     same Refund object instead of double-refunding.
  #   - DB-side: relies on charge.refunded webhook to record the txn,
  #     which itself dedupes on stripe_refund_id.
  class IssueStripeRefund
    class Error < StandardError; end
    class MissingPaymentIntent < Error; end
    class InvalidAmount < Error; end
    class AlreadyFullyRefunded < Error; end
    class ExceedsRefundableBalance < Error; end

    def self.call(...)
      new(...).call
    end

    def initialize(gift_card:, amount_cents:, reason:, actor:)
      @gift_card = gift_card
      @amount_cents = amount_cents.to_i
      @reason = reason.to_s.strip.presence
      @actor = actor
    end

    def call
      raise MissingPaymentIntent if @gift_card.payment_intent_id.blank?
      raise InvalidAmount if @amount_cents <= 0

      # Hold the row lock through validation AND the Stripe call: redemptions
      # lock the same row, so the refundable balance cannot move (or be spent
      # at a register) between the cap check and the money leaving. Admin
      # refunds are rare, so briefly holding the lock across the external
      # call is an acceptable trade for closing that race.
      @gift_card.with_lock do
        raise AlreadyFullyRefunded if @gift_card.canceled?

        # Never refund value that has already been redeemed (the platform
        # owes/paid the merchant for it) or already refunded to the buyer.
        if @amount_cents > @gift_card.refundable_to_buyer_cents
          raise ExceedsRefundableBalance,
                "Requested #{@amount_cents} exceeds refundable #{@gift_card.refundable_to_buyer_cents} " \
                "for gift_card=#{@gift_card.id}"
        end

        create_stripe_refund
      end
    end

    private

    def create_stripe_refund
      idem_key = "refund:gc#{@gift_card.id}:#{@amount_cents}:#{@actor&.id}"

      refund = Stripe::Refund.create(
        {
          payment_intent: @gift_card.payment_intent_id,
          amount: @amount_cents,
          reason: stripe_reason,
          metadata: {
            gift_card_id: @gift_card.id.to_s,
            admin_user_id: @actor&.id.to_s,
            internal_reason: @reason.to_s
          }.compact
        },
        { idempotency_key: idem_key }
      )

      Rails.logger.info(
        "[StripeRefund] Created refund #{refund.id} for gift_card=#{@gift_card.id} " \
        "amount_cents=#{@amount_cents} actor=#{@actor&.id} reason=#{@reason.inspect}"
      )

      # Internal balance reconciliation is performed by the charge.refunded
      # webhook to keep a single code path. If the webhook doesn't land
      # (Stripe outage, misconfig), admin can re-run reconciliation manually.
      refund
    end

    # Map our internal reason to one of Stripe's accepted reason codes.
    # Free-form text goes in metadata.internal_reason for the audit trail.
    def stripe_reason
      case @reason.to_s.downcase
      when /fraud/, /unauthorized/, /stolen/
        "fraudulent"
      when /duplicate/
        "duplicate"
      else
        "requested_by_customer"
      end
    end
  end
end
