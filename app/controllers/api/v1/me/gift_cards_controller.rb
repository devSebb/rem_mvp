module Api
  module V1
    module Me
      class GiftCardsController < Api::V1::BaseController
        before_action :set_gift_card, only: [:show, :redemption_token]

        def index
          gift_cards = policy_scope(GiftCard)
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
          @gift_card = policy_scope(GiftCard).find(params[:id])
        end

        def serialize_gift_card(card)
          {
            id: card.id,
            amount_cents: card.amount,
            remaining_balance_cents: card.remaining_balance,
            currency: card.currency,
            status: card.status,
            expires_at: card.expires_at&.iso8601,
            merchant_id: card.merchant_id
          }
        end
      end
    end
  end
end

