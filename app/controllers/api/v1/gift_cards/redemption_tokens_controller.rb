module Api
  module V1
    module GiftCards
      class RedemptionTokensController < ApplicationController
        skip_before_action :verify_authenticity_token
        before_action :set_gift_card

        def create
          return unless @gift_card

          authorize @gift_card, :view_code?

          if @gift_card.frozen_by_admin?
            return render json: { error: "Esta tarjeta está congelada.", code: "gift_card.frozen" }, status: :unprocessable_entity
          end

          unless @gift_card.active?
            return render json: { error: "Tarjeta inactiva o no disponible", code: "gift_card.inactive" }, status: :unprocessable_entity
          end

          spendable = @gift_card.spendable_cents
          if spendable <= 0
            return render json: { error: "Esta tarjeta no tiene saldo disponible ahora.", code: "gift_card.no_spendable_balance" }, status: :unprocessable_entity
          end

          result = RedemptionTokens::Issue.call(gift_card: @gift_card)

          render json: {
            token: result[:token],
            expires_at: result[:expires_at].iso8601,
            spendable_cents: spendable
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

