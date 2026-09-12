require "securerandom"

module Refunds
  # Type A reversal (§5.5): a merchant undoes one of its own redemptions.
  # No money moves at Stripe; the cents go back onto exactly the loads the
  # redemption debited (Loads::Allocator.credit_reversal!). Full amount,
  # once per redemption (DB index on reversal_of_transaction_id). Card
  # status is untouched (D3): a reversal never "reactivates" anything.
  class Issue
    class ValidationError < StandardError; end

    def self.call(...)
      new(...).call
    end

    def initialize(merchant:, redemption_transaction_id:, actor: nil, reason: nil, idempotency_key: nil)
      @merchant = merchant
      @redemption_transaction_id = redemption_transaction_id
      @actor = actor
      @reason = reason.to_s.strip.presence
      @idempotency_key = idempotency_key.to_s.strip.presence
    end

    def call
      validate_request!

      if idempotency_key.present? && (existing = existing_transaction)
        return build_payload(existing)
      end

      redemption = locate_redemption!

      ActiveRecord::Base.transaction do
        gift_card = redemption.gift_card
        raise ValidationError, "Gift card not found for transaction" unless gift_card

        gift_card.with_lock do
          gift_card.reload

          raise ValidationError, "Redemption already refunded" if already_refunded?(redemption)

          refund_txn = create_refund_transaction!(gift_card:, redemption:)
          # A concurrent/idempotent replay returned the existing row: nothing
          # more to move.
          if refund_txn.redemption_allocations.exists?
            return build_payload(refund_txn, original_transaction: redemption)
          end

          credits = Loads::Allocator.credit_reversal!(card: gift_card, reversal: refund_txn, redemption: redemption)
          shortfalls = credits.select(&:shortfall_load)
          if shortfalls.any? # the allocator recorded shortfall_cents on the row; this is the only out-of-order money path
            AdminAlertMailer.reversal_shortfall(gift_card.id, refund_txn.id, shortfalls.sum { |c| c.shortfall_load.amount_cents }).deliver_later
          end

          build_payload(refund_txn, original_transaction: redemption, balances: gift_card.balances)
        end
      end
    end

    private

    attr_reader :merchant, :redemption_transaction_id, :actor, :reason, :idempotency_key

    def validate_request!
      raise ValidationError, "merchant is required" unless merchant
      raise ValidationError, "redemption_transaction_id is required" if redemption_transaction_id.blank?
    end

    def locate_redemption!
      txn = Transaction.includes(:gift_card).find_by(id: redemption_transaction_id, merchant_id: merchant.id)
      raise ActiveRecord::RecordNotFound unless txn
      raise ValidationError, "Transaction is not a successful redemption" unless txn.redemption? && txn.succeeded?

      txn
    end

    def existing_transaction
      Transaction.refunds.includes(:gift_card).find_by(merchant_id: merchant.id, idempotency_key: idempotency_key)
    end

    def already_refunded?(redemption)
      Transaction.reversals.where(reversal_of_transaction_id: redemption.id).exists?
    end

    def create_refund_transaction!(gift_card:, redemption:)
      Transaction.create!(
        gift_card: gift_card,
        merchant: merchant,
        user: actor,
        amount: redemption.amount,
        currency: redemption.currency || gift_card.currency || "USD",
        txn_type: :refund,
        status: :succeeded,
        processor_ref: "refund_#{SecureRandom.uuid}",
        idempotency_key: idempotency_key,
        reversal_of_transaction_id: redemption.id,
        merchant_reference: redemption.merchant_reference,
        metadata: {
          refund_of_transaction_id: redemption.id,
          original_processor_ref: redemption.processor_ref,
          original_transaction_status: redemption.status,
          reason: reason,
          refunded_at: Time.current.iso8601,
          actor_id: actor&.id,
          actor_type: actor&.class&.name
        }.compact
      )
    rescue ActiveRecord::RecordNotUnique
      txn = Transaction.find_by(merchant_id: merchant.id, idempotency_key: idempotency_key) if idempotency_key
      txn ||= Transaction.reversals.find_by(reversal_of_transaction_id: redemption.id)
      return txn if txn&.refund?

      raise ValidationError, "idempotency_key already used"
    end

    def build_payload(refund_txn, original_transaction: nil, balances: nil)
      gift_card = refund_txn.gift_card
      balances ||= gift_card&.reload&.balances || { spendable_cents: 0, remaining_balance: 0 }
      original_id = original_transaction&.id || refund_txn.metadata["refund_of_transaction_id"]

      {
        approved: refund_txn.succeeded?,
        status: refund_txn.status,
        refund_transaction_id: refund_txn.id,
        original_transaction_id: original_id&.to_i,
        gift_card_id: gift_card&.id,
        amount_cents: refund_txn.amount,
        remaining_balance_cents: balances[:remaining_balance],
        spendable_cents: balances[:spendable_cents],
        currency: refund_txn.currency || gift_card&.currency || "USD"
      }
    end
  end
end
