module Api
  module V1
    module Me
      # GET /me/activity?cursor=&limit= (§8.2) — the "Historial" tab.
      class ActivityController < Api::V1::BaseController
        def index
          page = ::Activity::Feed.call(user: current_user, cursor: params[:cursor], limit: params[:limit])

          render_success(data: {
            events: page[:events].map { |e| serialize(e) },
            next_cursor: page[:next_cursor]
          })
        end

        private

        def serialize(event)
          {
            type: event.type,
            amount_cents: event.amount_cents,
            currency: event.currency,
            gift_card_id: event.gift_card_id,
            load_id: event.load_id,
            transaction_id: event.transaction_id,
            merchant: event.merchant,
            counterpart: event.counterpart,
            created_at: event.created_at&.iso8601
          }
        end
      end
    end
  end
end
