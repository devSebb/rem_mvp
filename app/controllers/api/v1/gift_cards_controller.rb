module Api
  module V1
    # Merchant-facing balance checks on a redemption token (§8.4). Request
    # shapes are unchanged; `remaining_balance_cents` / `balance_cents` now
    # mean "what this card can spend right now" (§5.4), with the total
    # incl. held/disputed funds exposed as `total_balance_cents`.
    class GiftCardsController < MerchantBaseController
      before_action :set_token_context
      before_action :ensure_merchant_can_redeem!, only: [:validate, :show]

      def validate
        return unless ensure_token_active!(include_validation_payload: true)

        amount_cents = normalize_amount_cents

        return unless ensure_gift_card_redeemable!

        if balances[:spendable_cents] < amount_cents
          return render json: insufficient_funds_payload, status: :unprocessable_entity
        end

        render json: success_validation_payload, status: :ok
      end

      def show
        return unless ensure_token_active!

        render json: {
          gift_card_id: gift_card.id,
          balance_cents: balances[:spendable_cents],
          spendable_cents: balances[:spendable_cents],
          total_balance_cents: balances[:remaining_balance],
          held_cents: balances[:held_cents],
          disputed_cents: balances[:disputed_cents],
          currency: gift_card.currency,
          status: gift_card.public_status
        }, status: :ok
      end

      private

      attr_reader :gift_card, :redemption_token

      def balances
        @balances ||= gift_card.balances
      end

      def set_token_context
        raw_token = params.require(:token).to_s.strip.upcase
        digest = RedemptionToken.digest(raw_token)

        @redemption_token = RedemptionToken.includes(:gift_card).find_by!(token_digest: digest)
        @gift_card = @redemption_token.gift_card || raise(ActiveRecord::RecordNotFound)
      end

      # D6: only the issuing merchant or one in its redemption group may
      # act on the card. Same envelope the redemption endpoint uses.
      def ensure_merchant_can_redeem!
        return true if Merchants::CanRedeem.call(redeemer: current_merchant, issuer: gift_card.merchant)

        render json: base_validation_payload.merge(valid: false, error: "merchant_mismatch"), status: :forbidden
        false
      end

      def normalize_amount_cents
        amount = params.require(:amount_cents).to_i
        if amount <= 0
          raise ActionController::ParameterMissing, "amount_cents must be greater than 0"
        end

        amount
      end

      def ensure_token_active!(include_validation_payload: false)
        if redemption_token.expires_at <= Time.current
          render_token_error("expired_token", include_validation_payload)
          return false
        end

        if redemption_token.used_at.present?
          render_token_error("token_used", include_validation_payload)
          return false
        end

        true
      end

      def ensure_gift_card_redeemable!
        if gift_card.frozen_by_admin?
          render json: base_validation_payload.merge(valid: false, error: "card_frozen"), status: :unprocessable_entity
          return false
        end
        return true if gift_card.active?

        render json: invalid_gift_card_payload, status: :unprocessable_entity
        false
      end

      def render_token_error(error_key, include_validation_payload)
        payload = { error: error_key }
        if include_validation_payload
          payload.merge!(base_validation_payload.merge(valid: false))
        end

        render json: payload, status: :unprocessable_entity
      end

      def invalid_gift_card_payload
        base_validation_payload.merge(
          valid: false,
          error: "inactive_gift_card"
        )
      end

      def insufficient_funds_payload
        base_validation_payload.merge(
          valid: false,
          error: "insufficient_funds"
        )
      end

      def success_validation_payload
        base_validation_payload.merge(valid: true)
      end

      def base_validation_payload
        {
          gift_card_id: gift_card.id,
          remaining_balance_cents: balances[:spendable_cents],
          spendable_cents: balances[:spendable_cents],
          total_balance_cents: balances[:remaining_balance],
          held_cents: balances[:held_cents],
          disputed_cents: balances[:disputed_cents],
          currency: gift_card.currency
        }
      end
    end
  end
end
