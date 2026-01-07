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
        transaction = Transaction.find_by!(merchant_id: current_merchant.id, id: params[:id])
        result = {
          transaction: transaction,
          approved: transaction.succeeded?,
          status: transaction.status,
          decline_reason: transaction.decline_reason,
          transaction_id: transaction.id,
          gift_card_id: transaction.gift_card_id,
          amount_cents: transaction.amount,
          remaining_balance_cents: transaction.gift_card&.remaining_balance,
          currency: transaction.currency
        }

        render json: format_response(result), status: :ok
      end

      def refund
        idempotency_key = params.require(:idempotency_key)
        reason = params[:reason]

        result = Refunds::Issue.call(
          merchant: current_merchant,
          redemption_transaction_id: params[:id],
          actor: nil,
          reason: reason,
          idempotency_key: idempotency_key
        )

        render json: result, status: :ok
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
          transaction_id: result[:transaction_id],
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

