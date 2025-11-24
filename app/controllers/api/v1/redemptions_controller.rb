module Api
  module V1
    class RedemptionsController < MerchantBaseController
      def create
        result = Redemptions::AuthorizeAndCapture.call(
          merchant: current_merchant,
          raw_token: redemption_params[:token],
          amount_cents: redemption_params[:amount_cents],
          idempotency_key: redemption_params[:idempotency_key],
          merchant_reference: redemption_params[:merchant_reference]
        )

        render json: format_response(result), status: :ok
      end

      def show
        redemption = current_merchant.redemptions.find(params[:id])
        result = {
          redemption: redemption,
          approved: redemption.approved?,
          status: redemption.status,
          decline_reason: redemption.decline_reason,
          redemption_id: redemption.id,
          gift_card_id: redemption.gift_card_id,
          amount_cents: redemption.amount_cents,
          remaining_balance_cents: redemption.gift_card&.remaining_balance,
          currency: redemption.currency
        }

        render json: format_response(result), status: :ok
      end

      private

      def redemption_params
        params.require(:token)
        params.require(:amount_cents)
        params.require(:idempotency_key)

        params.permit(:token, :amount_cents, :idempotency_key, :merchant_reference)
      end

      def format_response(result)
        payload = {
          approved: result[:approved],
          status: result[:status],
          redemption_id: result[:redemption_id],
          gift_card_id: result[:gift_card_id],
          amount_cents: result[:amount_cents],
          remaining_balance_cents: result[:remaining_balance_cents],
          currency: result[:currency]
        }

        payload[:decline_reason] = result[:decline_reason] if result[:decline_reason].present?
        payload
      end
    end
  end
end

