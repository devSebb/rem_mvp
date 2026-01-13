require "securerandom"

module Redemptions
  class AuthorizeAndCapture
    class ValidationError < StandardError; end

    def self.call(...)
      new(...).call
    end

    def initialize(merchant:, raw_token:, amount_cents:, idempotency_key:, merchant_reference: nil)
      @merchant = merchant
      @raw_token = raw_token&.strip&.upcase
      @amount_cents = amount_cents.to_i
      @idempotency_key = idempotency_key&.strip
      @merchant_reference = merchant_reference
      @transaction_merchant_id = merchant&.id
    end

    def call
      validate_request!

      if (existing = existing_transaction)
        return build_payload(existing)
      end

      ActiveRecord::Base.transaction do
        process_request
      end
    end

    private

    attr_reader :merchant, :raw_token, :amount_cents, :idempotency_key, :merchant_reference, :transaction_merchant_id

    def process_request
      token = locate_token
      return decline!("invalid_token") unless token

      token.with_lock do
        gift_card = token.gift_card
        return decline!("invalid_token") unless gift_card

        unless gift_card&.merchant_id
          return decline_without_transaction!("merchant_missing", gift_card: gift_card)
        end

        set_transaction_merchant(gift_card)

        unless gift_card.merchant_id == merchant.id
          return decline_without_transaction!("merchant_mismatch", gift_card: gift_card)
        end

        return decline!("expired_token", token: token, gift_card: gift_card) if token_expired?(token)
        return decline!("token_used", token: token, gift_card: gift_card) if token.used_at.present?
        return decline!("gift_card_inactive", token: token, gift_card: gift_card) unless gift_card&.active? && !gift_card.expired?

        if (existing = existing_transaction)
          return build_payload(existing)
        end

        process_with_gift_card(token, gift_card)
      end
    end

    def process_with_gift_card(token, gift_card)
      gift_card.with_lock do
        begin
          new_balance = gift_card.redeem_amount!(amount_cents)
        rescue GiftCard::RedemptionError => e
          reason = e.reason == :insufficient_balance ? "insufficient_balance" : "gift_card_inactive"
          return decline!(reason, token: token, gift_card: gift_card)
        end

        txn = create_transaction!(
          gift_card: gift_card,
          redemption_token: token,
          status: :succeeded,
          decline_reason: nil
        )
        token.update!(used_at: Time.current)

        build_payload(txn, remaining_balance_override: new_balance)
      end
    end

    def decline!(reason, token: nil, gift_card: nil)
      txn = create_transaction!(
        gift_card: gift_card,
        redemption_token: token,
        status: :failed,
        decline_reason: reason
      )

      build_payload(txn)
    end

    def set_transaction_merchant(gift_card)
      @transaction_merchant_id = gift_card&.merchant_id
    end

    def decline_without_transaction!(reason, gift_card:)
      {
        transaction: nil,
        approved: false,
        status: "failed",
        decline_reason: reason,
        transaction_id: nil,
        gift_card_id: gift_card&.id,
        amount_cents: amount_cents,
        remaining_balance_cents: gift_card&.remaining_balance,
        currency: gift_card&.currency || "USD"
      }
    end

    def existing_transaction
      return nil unless transaction_merchant_id

      @existing_transaction ||= Transaction
                                .includes(:gift_card)
                                .find_by(merchant_id: transaction_merchant_id, idempotency_key: idempotency_key)
    end

    def locate_token
      digest = RedemptionToken.digest(raw_token)
      RedemptionToken.find_by(token_digest: digest)
    end

    def token_expired?(token)
      token.expires_at <= Time.current
    end

    def validate_request!
      raise ValidationError, "token is required" if raw_token.blank?
      raise ValidationError, "amount_cents must be greater than 0" if amount_cents <= 0
      raise ValidationError, "idempotency_key is required" if idempotency_key.blank?
    end

    def build_payload(txn, remaining_balance_override: nil)
      gift_card = txn.gift_card
      remaining_balance = remaining_balance_override
      remaining_balance ||= gift_card&.reload&.remaining_balance

      {
        transaction: txn,
        approved: txn.succeeded?,
        status: txn.status,
        decline_reason: txn.decline_reason,
        transaction_id: txn.id,
        gift_card_id: gift_card&.id,
        amount_cents: txn.amount,
        remaining_balance_cents: remaining_balance,
        currency: txn.currency || gift_card&.currency || "USD"
      }
    end

    def create_transaction!(gift_card:, redemption_token:, status:, decline_reason:)
      txn_merchant_id = transaction_merchant_id || merchant&.id
      Transaction.create!(
        gift_card: gift_card,
        redemption_token: redemption_token,
        merchant_id: txn_merchant_id,
        amount: amount_cents,
        currency: gift_card&.currency || "USD",
        txn_type: :redemption,
        status: status,
        processor_ref: "merchant_api_redemption_#{SecureRandom.uuid}",
        idempotency_key: idempotency_key,
        merchant_reference: merchant_reference,
        decline_reason: decline_reason,
        metadata: {
          merchant_id: txn_merchant_id,
          merchant_reference: merchant_reference
        }.compact
      )
    rescue ActiveRecord::RecordNotUnique
      Transaction.find_by!(merchant_id: txn_merchant_id, idempotency_key: idempotency_key)
    end
  end
end

