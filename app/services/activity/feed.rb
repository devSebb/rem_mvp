require "base64"

module Activity
  # Server-side activity feed for one user (RELOADABLE_CARD_PLAN.md §8.2
  # `GET /me/activity`): loads received/sent/self, redemptions, merchant
  # reversals, Stripe refunds, dispute write-offs and released holds, newest
  # first, with an opaque cursor. Replaces the app's buildActivityFeed.
  #
  # Volumes per user are small (their own cards and purchases), so the feed
  # is assembled in Ruby from a handful of indexed queries and paginated by
  # cursor over the sorted list.
  class Feed
    Event = Struct.new(:type, :amount_cents, :currency, :gift_card_id, :load_id, :transaction_id,
                       :merchant, :counterpart, :created_at, keyword_init: true) do
      def key
        "#{created_at.utc.iso8601(6)}|#{type}|#{load_id || transaction_id || 0}"
      end
    end

    DEFAULT_LIMIT = 30
    MAX_LIMIT = 100

    def self.call(user:, cursor: nil, limit: DEFAULT_LIMIT)
      new(user).page(cursor: cursor, limit: limit)
    end

    def initialize(user)
      @user = user
    end

    # @return [Hash] { events: [Event], next_cursor: String|nil }
    def page(cursor:, limit:)
      limit = limit.to_i
      limit = DEFAULT_LIMIT unless limit.between?(1, MAX_LIMIT)
      all = events.sort_by { |e| [-e.created_at.to_f, e.type, -(e.load_id || e.transaction_id || 0)] }

      if cursor.present?
        after = decode(cursor)
        idx = all.index { |e| e.key == after }
        all = idx ? all[(idx + 1)..] : []
      end

      slice = all.first(limit)
      next_cursor = all.size > limit ? encode(slice.last.key) : nil
      { events: slice, next_cursor: next_cursor }
    end

    def events
      received_card_ids = GiftCard.not_merged.where(recipient_id: user.id).pluck(:id)
      loads = GiftCardLoad.in_scope
                          .where("gift_card_id IN (?) OR sender_id = ?", received_card_ids.presence || [0], user.id)
                          .includes(:sender, gift_card: [:recipient, :merchant])
                          .to_a

      out = []
      loads.each do |load|
        card = load.gift_card
        next unless card

        merchant = merchant_json(card.merchant)
        if load.self_load? && card.recipient_id == user.id
          out << event("load_self", load.amount_cents, load, merchant, nil, load.created_at)
        elsif card.recipient_id == user.id
          out << event("load_received", load.amount_cents, load, merchant, person(load.sender), load.created_at)
        elsif load.sender_id == user.id
          out << event("load_sent", load.amount_cents, load, merchant, person(card.recipient), load.created_at)
        end

        if load.hold_released? && card.recipient_id == user.id && load.remaining_cents.positive?
          out << event("hold_released", load.remaining_cents, load, merchant, nil, load.held_until)
        end
      end

      txns = Transaction.successful
                        .where(gift_card_id: received_card_ids.presence || [0])
                        .where(txn_type: [:redemption, :refund, :adjustment])
                        .includes(:merchant, :gift_card_load, gift_card: :merchant)
                        .to_a
      # Stripe refunds also reach the buyer who paid the load.
      sent_load_ids = loads.select { |l| l.sender_id == user.id }.map(&:id)
      if sent_load_ids.any?
        txns |= Transaction.successful.stripe_refunds.where(gift_card_load_id: sent_load_ids)
                           .includes(:merchant, :gift_card_load, gift_card: :merchant).to_a
      end

      txns.each do |txn|
        card = txn.gift_card
        merchant = merchant_json(txn.merchant || card&.merchant)
        type =
          if txn.redemption? then "redemption"
          elsif txn.refund? && txn.reversal_of_transaction_id.present? then "reversal"
          elsif txn.refund? then "refund"
          elsif txn.adjustment? && txn.processor_ref.to_s.start_with?("dispute_") then "write_off"
          end
        next unless type
        next if type == "write_off" && txn.amount.to_i.zero?

        out << Event.new(type: type, amount_cents: txn.amount, currency: txn.currency || card&.currency || "USD",
                         gift_card_id: txn.gift_card_id, load_id: txn.gift_card_load_id, transaction_id: txn.id,
                         merchant: merchant, counterpart: nil, created_at: txn.created_at)
      end

      out
    end

    private

    attr_reader :user

    def event(type, cents, load, merchant, counterpart, at)
      Event.new(type: type, amount_cents: cents, currency: load.currency, gift_card_id: load.gift_card_id,
                load_id: load.id, transaction_id: nil, merchant: merchant, counterpart: counterpart, created_at: at)
    end

    def merchant_json(merchant)
      return nil unless merchant

      { id: merchant.id, store_name: merchant.store_name }
    end

    def person(u)
      return nil unless u

      { id: u.id, name: u.first_name.presence || u.name.presence }
    end

    def encode(key)
      Base64.urlsafe_encode64(key, padding: false)
    end

    def decode(cursor)
      Base64.urlsafe_decode64(cursor.to_s)
    rescue ArgumentError
      ""
    end
  end
end
