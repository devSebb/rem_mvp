module Api
  module V1
    module Me
      class GiftCardsController < Api::V1::BaseController
        include LoadSharing

        before_action :set_gift_card, only: [:show, :redemption_token, :share_link, :resend]

        def index
          gift_cards = policy_scope(GiftCard)
            .not_merged
            .includes(merchant: { logo_attachment: :blob }, loads: { sender: { avatar_attachment: :blob } })
            .order(updated_at: :desc, id: :desc)

          # Balance views are an "indication of interest" (§14.2 escheat):
          # batch update to avoid N+1.
          gift_card_ids = gift_cards.pluck(:id)
          GiftCard.where(id: gift_card_ids).update_all(last_owner_activity_at: Time.current) if gift_card_ids.any?

          render_success(data: gift_cards.map { |card| serialize_gift_card(card) })
        end

        def show
          authorize @gift_card, :show?
          @gift_card.touch_owner_activity!
          render_success(data: serialize_gift_card(@gift_card))
        end

        # Post-checkout polling endpoint (§5.3): the app polls with the Stripe
        # payment intent id until the webhook creates the LOAD, so a 404 means
        # "not created yet" and is part of the contract. Answers with the card
        # serialized at top level (old-app compat) plus `load` and its `top_up`
        # alias. Visible to the load's buyer or the card's recipient; anyone
        # else gets the same 404 (no existence leak).
        def by_payment_intent
          load = GiftCardLoad.includes(:sender, gift_card: [:recipient, :loads, { merchant: { logo_attachment: :blob } }])
                             .find_by!(payment_intent_id: params[:payment_intent_id])
          gift_card = load.gift_card
          raise ActiveRecord::RecordNotFound unless load.sender_id == current_user.id || gift_card.recipient_id == current_user.id

          gift_card.touch_owner_activity!
          serializer = GiftCardSerializer.new(gift_card, attachment_url: method(:attachment_url))
          data = serializer.as_json
          data[:load] = serializer.serialize_load(load)
          data[:top_up] = data[:load]
          render_success(data: data)
        end

        # §8.3: 422 `gift_card.frozen` / `gift_card.no_spendable_balance`;
        # the response carries `spendable_cents` so the app can show it.
        def redemption_token
          authorize @gift_card, :view_code?

          if @gift_card.frozen_by_admin?
            return render_error(
              code: "gift_card.frozen",
              message: "Esta tarjeta está congelada. Escríbenos si crees que es un error.",
              status: :unprocessable_entity
            )
          end

          unless @gift_card.active?
            return render_error(
              code: "gift_card.inactive",
              message: "Tarjeta inactiva o no disponible",
              status: :unprocessable_entity
            )
          end

          balances = @gift_card.balances
          if balances[:spendable_cents] <= 0
            return render_error(
              code: "gift_card.no_spendable_balance",
              message: "Esta tarjeta no tiene saldo disponible ahora.",
              status: :unprocessable_entity,
              details: {
                spendable_cents: balances[:spendable_cents],
                held_cents: balances[:held_cents],
                disputed_cents: balances[:disputed_cents],
                held_until: balances[:held_until]&.iso8601
              }.compact
            )
          end

          result = RedemptionTokens::Issue.call(gift_card: @gift_card)

          render_success(
            data: {
              token: result[:token],
              expires_at: result[:expires_at].iso8601,
              spendable_cents: balances[:spendable_cents]
            }
          )
        end

        # Card-level compat shims for the store app (§5.9): act on the latest
        # load the current user paid onto this card. Per-load routes live in
        # Me::LoadsController.
        def share_link
          authorize @gift_card, :share?
          load = @gift_card.latest_load_sent_by(current_user)
          return render_no_load unless load

          render_share_link(load)
        end

        def resend
          authorize @gift_card, :share?
          load = @gift_card.latest_load_sent_by(current_user)
          return render_no_load unless load

          render_resend(load)
        end

        private

        def render_no_load
          render_error(
            code: "gift_card.no_load_sent",
            message: "No has recargado esta tarjeta.",
            status: :unprocessable_entity
          )
        end

        def set_gift_card
          @gift_card = policy_scope(GiftCard)
            .not_merged
            .includes(merchant: { logo_attachment: :blob }, loads: { sender: { avatar_attachment: :blob } })
            .find(params[:id])
        end

        # §8.1 shape, compat fields included (GiftCardSerializer).
        def serialize_gift_card(card)
          GiftCardSerializer.call(card, attachment_url: method(:attachment_url))
        end
      end
    end
  end
end
