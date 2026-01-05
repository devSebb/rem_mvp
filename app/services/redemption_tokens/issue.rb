require "securerandom"

module RedemptionTokens
  class Issue
    TTL = 90.seconds
    REFRESH_THRESHOLD = 15.seconds
    RATE_LIMIT_WINDOW = 10.seconds
    CACHE_NAMESPACE = "redemption_tokens:raw"

    def self.call(...)
      new(...).call
    end

    def initialize(gift_card:)
      @gift_card = gift_card
    end

    def call
      gift_card.with_lock do
        if reusable_token?(latest_active_token)
          token = latest_active_token
          raw = fetch_raw_token(token)
          return payload(raw, token.expires_at) if raw.present?

          Rails.logger.warn("⚠️ Missing cached redemption token for gift_card_id=#{gift_card.id}; rotating")
          expire!(token)
        elsif (token = latest_active_token)
          expire!(token)
        end

        issue_fresh_token
      end
    end

    private

    attr_reader :gift_card

    def latest_active_token
      @latest_active_token ||= gift_card.redemption_tokens.active.order(expires_at: :desc).first
    end

    def reusable_token?(token)
      return false unless token

      remaining_time(token) > REFRESH_THRESHOLD || recently_issued?(token)
    end

    def recently_issued?(token)
      token.created_at && token.created_at > RATE_LIMIT_WINDOW.ago
    end

    def remaining_time(token)
      token.expires_at - Time.current
    end

    def expire!(token)
      token.update!(expires_at: Time.current)
      Rails.cache.delete(cache_key(token))
    end

    def issue_fresh_token
      raw_token = SecureRandom.base58(10).upcase
      digest = RedemptionToken.digest(raw_token)
      expires_at = TTL.from_now

      token = gift_card.redemption_tokens.create!(
        token_digest: digest,
        expires_at: expires_at
      )

      store_raw_token(token, raw_token, expires_at)

      Rails.logger.info("🔐 Issued redemption token gift_card_id=#{gift_card.id} expires_at=#{expires_at.iso8601}")

      payload(raw_token, expires_at)
    end

    def store_raw_token(token, raw_token, expires_at)
      ttl = [(expires_at - Time.current).to_i, 1].max
      Rails.cache.write(cache_key(token), raw_token, expires_in: ttl)
    end

    def fetch_raw_token(token)
      Rails.cache.read(cache_key(token))
    end

    def cache_key(token)
      "#{CACHE_NAMESPACE}:#{token.id}"
    end

    def payload(raw_token, expires_at)
      { token: raw_token, expires_at: expires_at }
    end
  end
end






