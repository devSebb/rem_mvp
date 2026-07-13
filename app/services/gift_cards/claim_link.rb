require "openssl"
require "digest"

module GiftCards
  # Lifecycle of a gift card's claim link (https://papayal.app/claim/<token>).
  #
  # The token is an HMAC of the card id keyed by the app secret, so it is
  # stable across re-shares without storing plaintext anywhere. The
  # link_token_digest column gives an indexed lookup and acts as the
  # revocation switch; link_token_expires_at is a sliding TTL refreshed on
  # every (re)issue.
  #
  # A claim link is a doorway, not a key: it only ever exposes the public
  # teaser (Api::V1::ClaimLinksController) and funnels the recipient into
  # signup, where Auth::ClaimVerification's OTP still guards the claim.
  class ClaimLink
    TTL = 90.days
    TOKEN_LENGTH = 32
    HMAC_PURPOSE = "gift_card_claim_link".freeze

    class << self
      # Returns the raw token, persisting the digest and a refreshed expiry.
      # update_columns keeps updated_at (wallet sort order) untouched.
      def issue!(gift_card)
        token = token_for(gift_card)
        gift_card.update_columns(
          link_token_digest: digest(token),
          link_token_expires_at: TTL.from_now
        )
        token
      end

      def url_for(gift_card)
        AppLinks.claim_url(issue!(gift_card))
      end

      # Returns the gift card for a valid, unexpired token; nil otherwise.
      # Status filtering is left to callers so they can render a friendly
      # "already redeemed" state instead of a generic not-found.
      def find_by_token(raw_token)
        return nil if raw_token.blank?

        gift_card = GiftCard.find_by(link_token_digest: digest(raw_token.to_s))
        return nil unless gift_card
        return nil if gift_card.link_token_expires_at.nil? || gift_card.link_token_expires_at <= Time.current

        gift_card
      end

      def revoke!(gift_card)
        gift_card.update_columns(link_token_digest: nil, link_token_expires_at: nil)
      end

      private

      def token_for(gift_card)
        OpenSSL::HMAC.hexdigest("SHA256", hmac_key, "#{HMAC_PURPOSE}:#{gift_card.id}")[0, TOKEN_LENGTH]
      end

      def digest(raw_token)
        Digest::SHA256.hexdigest(raw_token)
      end

      def hmac_key
        Rails.application.credentials.secret_key_base || Rails.application.secret_key_base
      end
    end
  end
end
