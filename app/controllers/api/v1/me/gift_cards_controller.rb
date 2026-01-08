module Api
  module V1
    module Me
      class GiftCardsController < Api::V1::BaseController
        before_action :set_gift_card, only: [:show, :redemption_token]

        def index
          gift_cards = policy_scope(GiftCard)
            .includes(:merchant)
            .order(updated_at: :desc, id: :desc)

          render_success(data: gift_cards.map { |card| serialize_gift_card(card) })
        end

        def show
          authorize @gift_card, :show?
          render_success(data: serialize_gift_card(@gift_card))
        end

        def redemption_token
          authorize @gift_card, :view_code?

          unless @gift_card.active?
            return render_error(
              code: "gift_card.inactive",
              message: "Tarjeta inactiva o no disponible",
              status: :unprocessable_entity
            )
          end

          result = RedemptionTokens::Issue.call(gift_card: @gift_card)

          render_success(
            data: {
              token: result[:token],
              expires_at: result[:expires_at].iso8601
            }
          )
        end

        private

        def set_gift_card
          @gift_card = policy_scope(GiftCard)
            .includes(:merchant)
            .find(params[:id])
        end

        def serialize_gift_card(card)
          {
            id: card.id,
            amount_cents: card.amount,
            remaining_balance_cents: card.remaining_balance,
            currency: card.currency,
            status: card.status,
            expires_at: card.expires_at&.iso8601,
            created_at: card.created_at&.iso8601,
            updated_at: card.updated_at&.iso8601,
            sender_id: card.sender_id,
            recipient_id: card.recipient_id,
            merchant_id: card.merchant_id,
            merchant: card.merchant ? { id: card.merchant.id, store_name: card.merchant.store_name } : nil,
            store_name: card.merchant&.store_name,
            merchant_name: card.merchant&.store_name
          }
        end
      end
    end
  end
end

