module Api
  module V1
    class ClaimLinksController < Api::V1::BaseController
      skip_before_action :authenticate_user_from_token!

      # Public teaser for a claim link (rate-limited in rack_attack). A link
      # resolves a LOAD (§8.2): the teaser shows that load's sender, amount
      # and note and the card's merchant. Deliberately minimal — enough for
      # the app or web fallback to personalize the claim flow, never enough
      # to redeem: no code, no full recipient identity, no card balance.
      def show
        load = ::GiftCards::ClaimLink.find_by_token(params[:token])

        unless load
          return render_error(
            code: "claim_link.not_found",
            message: "Este enlace no es válido o ya expiró",
            status: :not_found
          )
        end

        render_success(data: teaser(load))
      end

      private

      def teaser(load)
        gift_card = load.gift_card
        recipient = gift_card.recipient
        merchant = gift_card.merchant
        sender_name = load.sender&.first_name.presence
        is_reload = gift_card.first_load&.id != load.id
        amount = Messaging::Money.format(load.amount_cents, currency: load.currency)

        {
          gift_card_id: gift_card.id,
          load_id: load.id,
          status: gift_card.public_status,
          load_status: load.derived_status.to_s,
          is_reload: is_reload,
          amount_cents: load.amount_cents,
          currency: load.currency,
          merchant_name: merchant&.store_name,
          merchant_logo_url: attachment_url(merchant&.logo),
          sender_first_name: sender_name,
          note: load.note,
          recipient_masked_phone: mask_phone(recipient&.phone),
          recipient_registered: recipient&.claimed_at.present?,
          # §4.4 "Claim landing / share message" teaser lines
          teaser: if is_reload
                    "#{sender_name || 'Alguien'} recargó tu tarjeta de #{merchant&.store_name} con #{amount}"
                  else
                    "#{sender_name || 'Alguien'} te envió una tarjeta de regalo digital de #{merchant&.store_name} · #{amount}"
                  end
        }
      end

      # Same masking shape as Auth::ClaimVerification's signup response.
      def mask_phone(phone)
        return nil if phone.blank?

        digits = phone.to_s
        return "•••#{digits.last(2)}" if digits.length <= 8

        "#{digits.first(4)}•••#{digits.last(4)}"
      end
    end
  end
end
