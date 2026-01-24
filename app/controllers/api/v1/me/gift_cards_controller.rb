module Api
  module V1
    module Me
      class GiftCardsController < Api::V1::BaseController
        before_action :set_gift_card, only: [:show, :redemption_token]

        def index
          gift_cards = policy_scope(GiftCard)
            .includes(:sender, sender: { avatar_attachment: :blob }, merchant: { logo_attachment: :blob })
            .order(updated_at: :desc, id: :desc)

          # Track owner activity for balance check (batch update to avoid N+1)
          gift_card_ids = gift_cards.pluck(:id)
          GiftCard.where(id: gift_card_ids).update_all(last_owner_activity_at: Time.current) if gift_card_ids.any?

          render_success(data: gift_cards.map { |card| serialize_gift_card(card) })
        end

        def show
          authorize @gift_card, :show?
          # Track owner activity for balance check
          @gift_card.touch_owner_activity!
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
            .includes(:sender, sender: { avatar_attachment: :blob }, merchant: { logo_attachment: :blob })
            .find(params[:id])
        end

        def serialize_gift_card(card)
          {
            id: card.id,
            amount_cents: card.amount,
            remaining_balance_cents: card.remaining_balance,
            currency: card.currency,
            status: card.status,
            # expires_at removed - gift cards never expire
            created_at: card.created_at&.iso8601,
            updated_at: card.updated_at&.iso8601,
            sender_id: card.sender_id,
            recipient_id: card.recipient_id,
            merchant_id: card.merchant_id,
            merchant: card.merchant ? { id: card.merchant.id, store_name: card.merchant.store_name, logo_url: attachment_url(card.merchant.logo) } : nil,
            store_name: card.merchant&.store_name,
            merchant_name: card.merchant&.store_name,
            merchant_store_name: card.merchant&.store_name,
            merchant_logo_url: attachment_url(card.merchant&.logo),
            note: card.note,
            sender: serialize_sender(card.sender)
          }
        end

        def serialize_sender(sender)
          return nil unless sender

          {
            id: sender.id,
            name: sender.first_name,
            last_name: sender.last_name,
            full_name: sender.full_name.presence,
            email: sender.email,
            avatar_url: attachment_url(sender.avatar)
          }
        end
      end
    end
  end
end

