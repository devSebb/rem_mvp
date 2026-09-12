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

        status = if result[:approved]
          notify_recipient_of_redemption(result)
          :ok
        elsif result[:decline_reason] == "merchant_mismatch"
          :forbidden
        else
          :unprocessable_entity
        end

        render json: format_response(result), status: status
      end

      def show
        transaction = Transaction.find_by!(merchant_id: current_merchant.id, id: params[:id])
        balances = transaction.gift_card&.balances || {}
        result = {
          transaction: transaction,
          approved: transaction.succeeded?,
          status: transaction.status,
          decline_reason: transaction.decline_reason,
          transaction_id: transaction.id,
          gift_card_id: transaction.gift_card_id,
          amount_cents: transaction.amount,
          remaining_balance_cents: balances[:spendable_cents],
          spendable_cents: balances[:spendable_cents],
          total_balance_cents: balances[:remaining_balance],
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
      rescue Refunds::Issue::ValidationError => e
        render json: { error: e.message }, status: :unprocessable_entity
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
          # §8.4: keeps its name, now means "spendable right now"
          remaining_balance_cents: result[:remaining_balance_cents],
          spendable_cents: result[:spendable_cents],
          total_balance_cents: result[:total_balance_cents],
          currency: result[:currency]
        }

        payload[:decline_reason] = result[:decline_reason] if result[:decline_reason].present?
        payload[:held_until] = result[:held_until] if result[:held_until].present?
        payload[:held_cents] = result[:held_cents] if result.key?(:held_cents)
        payload[:disputed_cents] = result[:disputed_cents] if result.key?(:disputed_cents)
        payload
      end

      def notify_recipient_of_redemption(result)
        gift_card = GiftCard.find_by(id: result[:gift_card_id])
        return unless gift_card

        Messaging::RedemptionPusher.call(
          gift_card: gift_card,
          amount_cents: result[:amount_cents],
          merchant: current_merchant
        )
      rescue => e
        Rails.logger.warn "[RedemptionPusher] API enqueue failed for gift_card_id=#{result[:gift_card_id]}: #{e.class} - #{e.message}"
      end
    end
  end
end
