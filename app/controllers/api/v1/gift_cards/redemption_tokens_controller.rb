module Api
  module V1
    module GiftCards
      class RedemptionTokensController < ApplicationController
        before_action :set_gift_card

        def create
          return unless @gift_card

          authorize @gift_card, :view_code?

          unless @gift_card.active?
            return render json: { error: "Tarjeta inactiva o no disponible" }, status: :unprocessable_entity
          end

          result = RedemptionTokens::Issue.call(gift_card: @gift_card)

          render json: {
            token: result[:token],
            expires_at: result[:expires_at].iso8601
          }
        rescue StandardError => e
          Rails.logger.error("💥 Failed to issue redemption token: #{e.class} - #{e.message}")
          render json: { error: "No se pudo generar el código. Intenta nuevamente." }, status: :internal_server_error
        end

        private

        def set_gift_card
          @gift_card = GiftCard.find(params[:gift_card_id])
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Tarjeta no encontrada" }, status: :not_found
        end
      end
    end
  end
end

