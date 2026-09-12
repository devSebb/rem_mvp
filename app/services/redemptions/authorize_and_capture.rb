require "securerandom"

# Merchant redemption of a card via a 90 s bearer token (§5.4).
#
# Interface, lock order (token → card → loads) and idempotency semantics
# are unchanged from the pre-reloadable version: `(merchant_id,
# idempotency_key)` is replayed verbatim, declines included; `token.used_at`
# is set only on success.
#
# Declines, in check order:
#   invalid_token, expired_token, token_used, merchant_mismatch (D6),
#   gift_card_inactive (canceled/legacy), card_frozen (admin),
#   card_held_security_review (only held funds remain), card_disputed (only
#   disputed funds remain), insufficient_balance (amount > spendable).
#
# Capture draws the amount FIFO across the card's spendable loads through
# Loads::Allocator and records one allocation per load touched. Card status
# is never flipped to `redeemed` (D3).
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
        return decline_without_transaction!("merchant_missing", gift_card: gift_card) unless gift_card.merchant_id

        if (existing = existing_transaction)
          return build_payload(existing)
        end

        return decline!("expired_token", token: token, gift_card: gift_card) if token_expired?(token)
        return decline!("token_used", token: token, gift_card: gift_card) if token.used_at.present?

        unless Merchants::CanRedeem.call(redeemer: merchant, issuer: gift_card.merchant)
          return decline!("merchant_mismatch", token: token, gift_card: gift_card)
        end

        gift_card.with_lock do
          gift_card.reload
          balances = gift_card.balances

          return decline!("card_frozen", token: token, gift_card: gift_card) if gift_card.frozen_by_admin?
          return decline!("gift_card_inactive", token: token, gift_card: gift_card) unless gift_card.active?

          if balances[:spendable_cents].zero?
            if balances[:held_cents].positive?
              return decline!("card_held_security_review", token: token, gift_card: gift_card, balances: balances)
            elsif balances[:disputed_cents].positive?
              return decline!("card_disputed", token: token, gift_card: gift_card, balances: balances)
            end
          end

          if amount_cents > balances[:spendable_cents]
            return decline!("insufficient_balance", token: token, gift_card: gift_card, balances: balances)
          end

          capture!(token, gift_card)
        end
      end
    end

    def capture!(token, gift_card)
      txn = create_transaction!(gift_card: gift_card, redemption_token: token, status: :succeeded, decline_reason: nil)

      begin
        Loads::Allocator.debit!(card: gift_card, amount_cents: amount_cents, transaction: txn)
      rescue Loads::Allocator::InsufficientSpendable
        # Cannot happen after the check above (same lock), kept as a belt.
        raise ActiveRecord::Rollback
      end

      token.update!(used_at: Time.current)
      gift_card.touch_owner_activity!

      build_payload(txn, balances: gift_card.balances)
    end

    def decline!(reason, token: nil, gift_card: nil, balances: nil)
      txn = create_transaction!(gift_card: gift_card, redemption_token: token, status: :failed, decline_reason: reason)
      build_payload(txn, balances: balances)
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
        remaining_balance_cents: 0,
        total_balance_cents: gift_card&.remaining_balance.to_i,
        spendable_cents: 0,
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
      RedemptionToken.find_by(token_digest: RedemptionToken.digest(raw_token))
    end

    def token_expired?(token)
      token.expires_at <= Time.current
    end

    def validate_request!
      raise ValidationError, "token is required" if raw_token.blank?
      raise ValidationError, "amount_cents must be greater than 0" if amount_cents <= 0
      raise ValidationError, "idempotency_key is required" if idempotency_key.blank?
    end

    # `remaining_balance_cents` keeps its name for API clients and now means
    # "what this card can spend right now" (§8.4); the total incl. held and
    # disputed funds is `total_balance_cents`.
    def build_payload(txn, balances: nil)
      gift_card = txn.gift_card
      balances ||= gift_card&.reload&.balances || { spendable_cents: 0, remaining_balance: 0, held_cents: 0, disputed_cents: 0, held_until: nil }

      payload = {
        transaction: txn,
        approved: txn.succeeded?,
        status: txn.status,
        decline_reason: txn.decline_reason,
        transaction_id: txn.id,
        gift_card_id: gift_card&.id,
        amount_cents: txn.amount,
        remaining_balance_cents: balances[:spendable_cents],
        spendable_cents: balances[:spendable_cents],
        total_balance_cents: balances[:remaining_balance],
        currency: txn.currency || gift_card&.currency || "USD"
      }

      case txn.decline_reason
      when "card_held_security_review"
        payload[:held_until] = balances[:held_until]&.iso8601 if balances[:held_until]
        payload[:held_cents] = balances[:held_cents]
      when "card_disputed", "insufficient_balance"
        payload[:held_cents] = balances[:held_cents]
        payload[:disputed_cents] = balances[:disputed_cents]
      end

      payload
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
          issuer_merchant_id: gift_card&.merchant_id,
          merchant_reference: merchant_reference
        }.compact
      )
    rescue ActiveRecord::RecordNotUnique
      Transaction.find_by!(merchant_id: txn_merchant_id, idempotency_key: idempotency_key)
    end
  end
end
