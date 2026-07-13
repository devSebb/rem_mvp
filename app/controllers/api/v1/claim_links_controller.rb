module Api
  module V1
    class ClaimLinksController < Api::V1::BaseController
      skip_before_action :authenticate_user_from_token!

      # Public teaser for a claim link (rate-limited in rack_attack).
      # Deliberately minimal: enough for the app or web fallback to
      # personalize the claim flow, never enough to redeem — no code,
      # no full recipient identity.
      def show
        gift_card = ::GiftCards::ClaimLink.find_by_token(params[:token])

        unless gift_card
          return render_error(
            code: "claim_link.not_found",
            message: "Este enlace no es válido o ya expiró",
            status: :not_found
          )
        end

        render_success(data: teaser(gift_card))
      end

      private

      def teaser(gift_card)
        recipient = gift_card.recipient

        {
          gift_card_id: gift_card.id,
          status: gift_card.status,
          amount_cents: gift_card.amount,
          currency: gift_card.currency,
          merchant_name: gift_card.merchant&.store_name,
          merchant_logo_url: attachment_url(gift_card.merchant&.logo),
          sender_first_name: gift_card.sender&.first_name,
          note: gift_card.note,
          recipient_masked_phone: mask_phone(recipient&.phone),
          recipient_registered: recipient&.claimed_at.present?
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
