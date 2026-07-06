module Refunds
  # Refunds a succeeded PaymentIntent whose fulfillment permanently failed —
  # the buyer paid but no gift card was (or ever will be) created. Without
  # this, Stripe retries the webhook for ~3 days and the money is then
  # silently kept.
  #
  # Idempotent at three levels so webhook re-deliveries can call it freely:
  #   - Refuses to run if a gift card exists for the PaymentIntent.
  #   - Stripe-side: fixed idempotency_key per PaymentIntent, and a charge
  #     that is already fully refunded is treated as success.
  #   - DB-side: the audit Transaction dedupes on processor_ref uniqueness.
  #
  # Records a gift-card-less refund Transaction as the audit trail and
  # alerts the admin team.
  class RefundOrphanedPayment
    class GiftCardExists < StandardError; end

    def self.call(...)
      new(...).call
    end

    def initialize(payment_intent:, reason:)
      @payment_intent = payment_intent
      @reason = reason.to_s
    end

    def call
      if GiftCard.exists?(payment_intent_id: @payment_intent.id)
        raise GiftCardExists, "Gift card exists for payment intent #{@payment_intent.id}; refusing to refund"
      end

      refund = create_stripe_refund
      return nil unless refund # already refunded on a previous delivery

      record_audit_transaction(refund)
      notify_admin(refund)
      refund
    end

    private

    def create_stripe_refund
      # No amount: full refund of the charge. Buyer gets back exactly what
      # they paid, including any partial-capture edge cases.
      Stripe::Refund.create(
        {
          payment_intent: @payment_intent.id,
          reason: "requested_by_customer",
          metadata: {
            source: "orphaned_payment_auto_refund",
            failure_reason: @reason
          }
        },
        { idempotency_key: "orphan_refund:#{@payment_intent.id}" }
      )
    rescue Stripe::InvalidRequestError => e
      raise unless e.code == "charge_already_refunded"

      Rails.logger.info "[OrphanRefund] Payment intent #{@payment_intent.id} already refunded; nothing to do"
      nil
    end

    # Audit trail without a gift card: lets admin/finance reconcile the
    # auto-refund and lets charge.refunded webhook dedupe on stripe_refund_id.
    def record_audit_transaction(refund)
      Transaction.create!(
        gift_card: nil,
        merchant: nil,
        user: User.find_by(id: @payment_intent.metadata&.[]("sender_id")),
        amount: refund.amount,
        currency: refund.currency&.upcase || "USD",
        txn_type: :refund,
        status: :succeeded,
        processor_ref: refund.id,
        metadata: {
          stripe_refund_id: refund.id,
          stripe_payment_intent_id: @payment_intent.id,
          failure_reason: @reason,
          refunded_at: Time.current.iso8601,
          source: "orphaned_payment_auto_refund"
        }
      )
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      # Duplicate delivery already recorded it, or validation noise — the
      # money is safe (refund exists at Stripe); never fail the webhook here.
      Rails.logger.warn "[OrphanRefund] Could not record audit transaction for #{refund.id}: #{e.message}"
    end

    def notify_admin(refund)
      AdminAlertMailer.orphaned_payment_refunded(
        @payment_intent.id,
        refund.amount,
        refund.currency&.upcase || "USD",
        @reason,
        refund.id
      ).deliver_later
    rescue => e
      Rails.logger.error "[OrphanRefund] Failed to enqueue admin alert for #{refund.id}: #{e.message}"
    end
  end
end
