require "openssl"
require "digest"

module GiftCards
  # Lifecycle of a LOAD's claim link (https://papayal.app/claim/<token>),
  # RELOADABLE_CARD_PLAN.md §5.9: the teaser shows that load's sender,
  # amount and note plus the card's merchant.
  #
  # The token is an HMAC of the load id keyed by the app secret, so it is
  # stable across re-shares without storing plaintext anywhere. The
  # link_token_digest column on gift_card_loads gives an indexed lookup and
  # acts as the revocation switch; link_token_expires_at is a sliding TTL
  # refreshed on every (re)issue.
  #
  # Links issued before Phase 3 were card-level (HMAC of the card id, digest
  # on gift_cards.link_token_digest). They keep resolving until they expire:
  # `find_by_token` falls back to the card digest and answers with the
  # card's first load, which is the load that link was sent for.
  #
  # A claim link is a doorway, not a key: it only ever exposes the public
  # teaser (Api::V1::ClaimLinksController) and funnels the recipient into
  # signup, where Auth::ClaimVerification's OTP still guards the claim.
  class ClaimLink
    TTL = 90.days
    TOKEN_LENGTH = 32
    HMAC_PURPOSE = "gift_card_load_claim_link".freeze
    LEGACY_HMAC_PURPOSE = "gift_card_claim_link".freeze

    class << self
      # Returns the raw token, persisting the digest and a refreshed expiry.
      # update_columns keeps updated_at untouched.
      def issue!(load)
        token = token_for(load)
        load.update_columns(
          link_token_digest: digest(token),
          link_token_expires_at: TTL.from_now
        )
        token
      end

      def url_for(load)
        AppLinks.claim_url(issue!(load))
      end

      # Returns the load for a valid, unexpired token; nil otherwise.
      # Status filtering is left to callers so they can render a friendly
      # "already used" state instead of a generic not-found.
      def find_by_token(raw_token)
        return nil if raw_token.blank?

        d = digest(raw_token.to_s)
        load = GiftCardLoad.find_by(link_token_digest: d)
        return load if load && load.link_token_expires_at.present? && load.link_token_expires_at > Time.current
        return nil if load

        legacy_card_load(d)
      end

      def revoke!(load)
        load.update_columns(link_token_digest: nil, link_token_expires_at: nil)
      end

      private

      # Pre-Phase-3 link: digest lives on the card. Answer with the card's
      # first (oldest, non-canceled) load — the one that link announced.
      def legacy_card_load(token_digest)
        card = GiftCard.find_by(link_token_digest: token_digest)
        return nil unless card
        return nil if card.link_token_expires_at.nil? || card.link_token_expires_at <= Time.current

        card.loads.in_scope.fifo.first
      end

      def token_for(load)
        OpenSSL::HMAC.hexdigest("SHA256", hmac_key, "#{HMAC_PURPOSE}:#{load.id}")[0, TOKEN_LENGTH]
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
