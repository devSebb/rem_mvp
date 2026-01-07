require "securerandom"

module Refunds
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

      if idempotency_key.present?
        if (existing = existing_transaction)
          return build_payload(existing)
        end
      end

      redemption = locate_redemption!

      ActiveRecord::Base.transaction do
        gift_card = redemption.gift_card
        raise ValidationError, "Gift card not found for transaction" unless gift_card

        gift_card.with_lock do
          gift_card.reload

          if already_refunded?(redemption)
            raise ValidationError, "Redemption already refunded"
          end

          new_balance = gift_card.remaining_balance.to_i + redemption.amount.to_i
          if new_balance > gift_card.amount.to_i
            raise ValidationError, "Refund would exceed original gift card amount"
          end

          refund_txn = create_refund_transaction!(gift_card:, redemption:)

          gift_card.update!(remaining_balance: new_balance)
          if gift_card.redeemed? && gift_card.remaining_balance.positive?
            gift_card.update!(status: :active, redeemed_at: nil)
          end

          build_payload(refund_txn, original_transaction: redemption, remaining_balance_override: new_balance)
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

      unless txn.redemption? && txn.succeeded?
        raise ValidationError, "Transaction is not a successful redemption"
      end

      txn
    end

    def existing_transaction
      Transaction.refunds.includes(:gift_card).find_by(merchant_id: merchant.id, idempotency_key: idempotency_key)
    end

    def already_refunded?(redemption)
      Transaction
        .refunds
        .where(merchant_id: merchant.id)
        .where("metadata->>'refund_of_transaction_id' = ?", redemption.id.to_s)
        .exists?
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
      txn = Transaction.find_by(merchant_id: merchant.id, idempotency_key: idempotency_key)
      return txn if txn&.refund?

      raise ValidationError, "idempotency_key already used"
    end

    def build_payload(refund_txn, original_transaction: nil, remaining_balance_override: nil)
      gift_card = refund_txn.gift_card
      remaining_balance = remaining_balance_override
      remaining_balance ||= gift_card&.reload&.remaining_balance

      original_id = original_transaction&.id || refund_txn.metadata["refund_of_transaction_id"]

      {
        approved: refund_txn.succeeded?,
        status: refund_txn.status,
        refund_transaction_id: refund_txn.id,
        original_transaction_id: original_id&.to_i,
        gift_card_id: gift_card&.id,
        amount_cents: refund_txn.amount,
        remaining_balance_cents: remaining_balance,
        currency: refund_txn.currency || gift_card&.currency || "USD"
      }
    end
  end
end


