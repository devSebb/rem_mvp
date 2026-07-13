module GiftCards
  # Sender-triggered re-delivery of a gift card notification ("the recipient
  # never got the WhatsApp"). Wraps Messaging::Notifier#resend_delivery in
  # per-card throttles so the button can't be used to spam the recipient:
  # one resend per COOLDOWN, at most DAILY_LIMIT per rolling day.
  class ResendDelivery
    COOLDOWN = 60.seconds
    DAILY_LIMIT = 3

    class Throttled < StandardError
      attr_reader :retry_in_seconds

      def initialize(retry_in_seconds)
        @retry_in_seconds = retry_in_seconds
        super("Resend throttled; retry in #{retry_in_seconds}s")
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(gift_card:)
      @gift_card = gift_card
    end

    def call
      enforce_cooldown!
      enforce_daily_limit!

      Rails.cache.write(cooldown_key, Time.current.to_i, expires_in: COOLDOWN)
      Rails.cache.increment(daily_key, 1, expires_in: 24.hours)

      ResendNotificationJob.perform_later(gift_card.id)
      true
    end

    private

    attr_reader :gift_card

    def enforce_cooldown!
      started_at = Rails.cache.read(cooldown_key)
      return if started_at.blank?

      elapsed = Time.current.to_i - started_at.to_i
      raise Throttled.new([COOLDOWN.to_i - elapsed, 1].max)
    end

    def enforce_daily_limit!
      count = Rails.cache.read(daily_key).to_i
      raise Throttled.new(24.hours.to_i) if count >= DAILY_LIMIT
    end

    def cooldown_key
      "gift_cards:resend:cooldown:#{gift_card.id}"
    end

    def daily_key
      "gift_cards:resend:daily:#{gift_card.id}"
    end
  end
end
