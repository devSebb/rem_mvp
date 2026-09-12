# §4.1 caps, enforced at PI creation (checkout) AND at webhook fulfilment
# (D7). Every value comes from PlatformSetting (admin-editable under the
# hard ceilings). Rolling windows; only Stripe-funded loads count toward
# velocity (admin issuance/adjustments are not purchases).
#
#   Loads::CapChecker.check!(buyer:, recipient:, merchant:, amount_cents:)
#     → returns the resolved card (or nil) and raises CapExceeded with the
#       §4.1 error code + details { limit_cents|limit, used, room, resets_at }
#
# `recipient` may be nil at checkout (not resolvable yet); recipient- and
# card-level caps are then skipped and re-checked at fulfilment (TOCTOU).
module Loads
  class CapChecker
    class CapExceeded < StandardError
      attr_reader :code, :details

      def initialize(code, details = {})
        @code = code
        @details = details
        super("checkout.#{code}: #{details.inspect}")
      end

      def error_code = "checkout.#{code}"
    end

    Result = Struct.new(:card, :current_balance_cents, :projected_balance_cents, keyword_init: true)

    DAY = 24.hours
    MONTH = 30.days

    def self.check!(buyer:, recipient:, merchant:, amount_cents:, settings: PlatformSetting.current)
      new(buyer: buyer, recipient: recipient, merchant: merchant, amount_cents: amount_cents, settings: settings).check!
    end

    def initialize(buyer:, recipient:, merchant:, amount_cents:, settings:)
      @buyer = buyer
      @recipient = recipient
      @merchant = merchant
      @amount = amount_cents.to_i
      @settings = settings
      @now = Time.current
    end

    def check!
      check_amount_range!
      check_buyer_not_blocked!
      check_buyer_daily!
      check_buyer_monthly!

      card = existing_card
      check_card_daily!(card) if card
      check_card_balance!(card)
      check_recipient_monthly! if @recipient

      current = card ? card.remaining_balance.to_i : 0
      Result.new(card: card, current_balance_cents: current, projected_balance_cents: current + @amount)
    end

    private

    attr_reader :buyer, :recipient, :merchant, :amount, :settings, :now

    def existing_card
      return nil unless recipient && merchant

      @existing_card ||= GiftCard.find_by(recipient_id: recipient.id, merchant_id: merchant.id, merged_into_id: nil)
    end

    def check_amount_range!
      min = GiftCardLoad::MIN_LOAD_CENTS
      max = settings.max_load_cents
      return if amount.between?(min, max)

      raise CapExceeded.new(:load_amount_out_of_range, min_cents: min, max_cents: max, amount_cents: amount)
    end

    # D4 / I13: any open chargeback, or an admin block, stops new loads.
    def check_buyer_not_blocked!
      return unless buyer&.purchases_blocked?

      raise CapExceeded.new(:buyer_dispute_open,
                            dispute_open_count: buyer.dispute_open_count,
                            blocked_at: buyer.purchases_blocked_at&.iso8601)
    end

    def check_buyer_daily!
      scope = stripe_loads.where(sender_id: buyer.id).where("gift_card_loads.created_at >= ?", now - DAY)
      count = scope.count
      if count >= settings.max_daily_loads_per_buyer
        raise CapExceeded.new(:buyer_daily_count_limit,
                              limit: settings.max_daily_loads_per_buyer, used: count, room: 0,
                              resets_at: resets_at(scope, DAY))
      end

      used = scope.sum(:amount_cents)
      room = settings.max_daily_load_per_buyer_cents - used
      return if amount <= room

      raise CapExceeded.new(:buyer_daily_limit,
                            limit_cents: settings.max_daily_load_per_buyer_cents, used_cents: used,
                            room_cents: [room, 0].max, resets_at: resets_at(scope, DAY))
    end

    def check_buyer_monthly!
      scope = stripe_loads.where(sender_id: buyer.id).where("gift_card_loads.created_at >= ?", now - MONTH)
      used = scope.sum(:amount_cents)
      room = settings.max_30d_load_per_buyer_cents - used
      return if amount <= room

      raise CapExceeded.new(:buyer_monthly_limit,
                            limit_cents: settings.max_30d_load_per_buyer_cents, used_cents: used,
                            room_cents: [room, 0].max, resets_at: resets_at(scope, MONTH))
    end

    def check_card_daily!(card)
      scope = stripe_loads.where(gift_card_id: card.id).where("gift_card_loads.created_at >= ?", now - DAY)
      count = scope.count
      if count >= settings.max_loads_per_card_per_day
        raise CapExceeded.new(:card_daily_count_limit,
                              limit: settings.max_loads_per_card_per_day, used: count, room: 0,
                              resets_at: resets_at(scope, DAY))
      end

      used = scope.sum(:amount_cents)
      room = settings.max_daily_load_per_card_cents - used
      return if amount <= room

      raise CapExceeded.new(:card_daily_load_limit,
                            limit_cents: settings.max_daily_load_per_card_cents, used_cents: used,
                            room_cents: [room, 0].max, resets_at: resets_at(scope, DAY))
    end

    def check_card_balance!(card)
      balance = card&.remaining_balance.to_i
      room = settings.max_card_balance_cents - balance
      return if amount <= room

      raise CapExceeded.new(:card_balance_limit,
                            limit_cents: settings.max_card_balance_cents, used_cents: balance,
                            room_cents: [room, 0].max, resets_at: nil)
    end

    def check_recipient_monthly!
      scope = stripe_loads.joins(:gift_card)
                          .where(gift_cards: { recipient_id: recipient.id })
                          .where("gift_card_loads.created_at >= ?", now - MONTH)
      used = scope.sum(:amount_cents)
      room = settings.max_30d_load_per_recipient_cents - used
      return if amount <= room

      raise CapExceeded.new(:recipient_monthly_limit,
                            limit_cents: settings.max_30d_load_per_recipient_cents, used_cents: used,
                            room_cents: [room, 0].max, resets_at: resets_at(scope, MONTH))
    end

    def stripe_loads
      GiftCardLoad.where(source: :stripe)
    end

    # When the oldest load inside the window falls out of it.
    def resets_at(scope, window)
      oldest = scope.minimum(:created_at)
      (oldest ? oldest + window : now).iso8601
    end
  end
end
