module Api
  module V1
    module Me
      class GiftCardsController < Api::V1::BaseController
        before_action :set_gift_card, only: [:show, :redemption_token, :share_link, :resend]

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

        # Post-checkout polling endpoint: the mobile app polls this with the
        # Stripe payment intent id until the webhook creates the card, so a
        # 404 here means "not created yet" and is part of the contract. The
        # policy scope also turns other users' cards into 404s (no existence leak).
        def by_payment_intent
          gift_card = policy_scope(GiftCard)
            .includes(:sender, sender: { avatar_attachment: :blob }, merchant: { logo_attachment: :blob })
            .find_by!(payment_intent_id: params[:payment_intent_id])

          # Track owner activity for balance check
          gift_card.touch_owner_activity!
          render_success(data: serialize_gift_card(gift_card))
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

        # Sender-side sharing for the native share sheet: the claim URL plus
        # a prewritten message. Copy lives server-side so wording can be
        # tuned without an app release. The link is a doorway, not a key —
        # claiming still requires the recipient's OTP at signup.
        def share_link
          authorize @gift_card, :share?

          unless @gift_card.active?
            return render_error(
              code: "gift_card.inactive",
              message: "Tarjeta inactiva o no disponible",
              status: :unprocessable_entity
            )
          end

          claim_url = ::GiftCards::ClaimLink.url_for(@gift_card)

          render_success(
            data: {
              claim_url: claim_url,
              message: share_message(claim_url)
            }
          )
        end

        # Sender-triggered re-delivery of the original notification
        # (WhatsApp/SMS/email/push). Throttled per card in
        # GiftCards::ResendDelivery so it can't spam the recipient.
        def resend
          authorize @gift_card, :share?

          unless @gift_card.active?
            return render_error(
              code: "gift_card.inactive",
              message: "Tarjeta inactiva o no disponible",
              status: :unprocessable_entity
            )
          end

          ::GiftCards::ResendDelivery.call(gift_card: @gift_card)

          render_success(data: { resent: true })
        rescue ::GiftCards::ResendDelivery::Throttled => e
          render_error(
            code: "gift_card.resend_throttled",
            message: "Ya reenviamos la notificación hace poco. Intenta de nuevo más tarde.",
            status: :too_many_requests,
            details: { retry_in_seconds: e.retry_in_seconds }
          )
        end

        private

        def share_message(claim_url)
          amount_label = "#{@gift_card.currency} #{format("%.2f", @gift_card.amount / 100.0)}"
          merchant_name = @gift_card.merchant&.store_name || "Papayal"

          <<~MESSAGE.strip
            🎁 ¡Te envié un regalo! Una tarjeta de #{amount_label} para #{merchant_name} en Papayal.

            👉 Reclámala aquí: #{claim_url}

            Crea tu cuenta con tu número de teléfono y la tarjeta te estará esperando. Sin fecha de vencimiento. 🎉
          MESSAGE
        end

        def set_gift_card
          @gift_card = policy_scope(GiftCard)
            .includes(:sender, sender: { avatar_attachment: :blob }, merchant: { logo_attachment: :blob })
            .find(params[:id])
        end

        def serialize_gift_card(card)
          merchant_logo_url = attachment_url(card.merchant&.logo)

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
            merchant: card.merchant ? { id: card.merchant.id, store_name: card.merchant.store_name, logo_url: merchant_logo_url } : nil,
            store_name: card.merchant&.store_name,
            merchant_name: card.merchant&.store_name,
            merchant_store_name: card.merchant&.store_name,
            merchant_logo_url: merchant_logo_url,
            note: card.note,
            sender: serialize_sender(card.sender),
            # Only expose held_until while it's still in the future. After
            # expiration we leave it null so the mobile UI doesn't need to
            # know about past holds.
            held_until: card.held? ? card.held_until.iso8601 : nil
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

