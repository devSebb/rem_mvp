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
    end

    def call
      validate_request!

      if (existing = existing_redemption)
        return build_payload(existing)
      end

      ActiveRecord::Base.transaction do
        process_request
      end
    end

    private

    attr_reader :merchant, :raw_token, :amount_cents, :idempotency_key, :merchant_reference

    def process_request
      token = locate_token
      return decline!("invalid_token") unless token

      token.with_lock do
        return decline!("expired_token", token: token, gift_card: token.gift_card) if token_expired?(token)
        return decline!("token_used", token: token, gift_card: token.gift_card) if token.used_at.present?

        gift_card = token.gift_card
        return decline!("gift_card_inactive", token: token, gift_card: gift_card) unless gift_card&.active? && !gift_card.expired?

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

        redemption = create_redemption!(
          status: :approved,
          gift_card: gift_card,
          redemption_token: token
        )

        create_transaction!(gift_card, redemption)
        token.update!(used_at: Time.current)

        build_payload(redemption, remaining_balance_override: new_balance)
      end
    end

    def decline!(reason, token: nil, gift_card: nil)
      redemption = create_redemption!(
        status: :declined,
        decline_reason: reason,
        gift_card: gift_card,
        redemption_token: token
      )

      build_payload(redemption)
    end

    def existing_redemption
      @existing_redemption ||= merchant.redemptions.includes(:gift_card).find_by(idempotency_key: idempotency_key)
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

    def create_redemption!(status:, gift_card:, redemption_token: nil, decline_reason: nil)
      merchant.redemptions.create!(
        gift_card: gift_card,
        redemption_token: redemption_token,
        status: status,
        decline_reason: decline_reason,
        amount_cents: amount_cents,
        currency: gift_card&.currency || "USD",
        idempotency_key: idempotency_key,
        merchant_reference: merchant_reference
      )
    rescue ActiveRecord::RecordNotUnique
      merchant.redemptions.for_idempotency(merchant.id, idempotency_key).first!
    end

    def build_payload(redemption, remaining_balance_override: nil)
      gift_card = redemption.gift_card
      remaining_balance = remaining_balance_override
      remaining_balance ||= gift_card&.reload&.remaining_balance

      {
        redemption: redemption,
        approved: redemption.approved?,
        status: redemption.status,
        decline_reason: redemption.decline_reason,
        redemption_id: redemption.id,
        gift_card_id: gift_card&.id,
        amount_cents: redemption.amount_cents,
        remaining_balance_cents: remaining_balance,
        currency: redemption.currency || gift_card&.currency || "USD"
      }
    end

    def create_transaction!(gift_card, redemption)
      gift_card.transactions.create!(
        amount: amount_cents,
        txn_type: :redemption,
        status: :succeeded,
        processor_ref: "merchant_api_redemption_#{SecureRandom.uuid}",
        metadata: {
          merchant_id: merchant.id,
          merchant_reference: merchant_reference,
          redemption_id: redemption.id
        }.compact
      )
    end
  end
end

