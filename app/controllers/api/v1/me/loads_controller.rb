module Api
  module V1
    module Me
      # Per-load endpoints (RELOADABLE_CARD_PLAN.md §8.2):
      #   GET  /me/gift_cards/:gift_card_id/loads          — the card's loads
      #   GET  /me/loads?role=sent                          — loads I paid ("Enviadas")
      #   POST /me/gift_cards/:gift_card_id/loads/:id/share_link
      #   POST /me/gift_cards/:gift_card_id/loads/:id/resend
      class LoadsController < Api::V1::BaseController
        include LoadSharing

        PER_PAGE = 20
        MAX_PER_PAGE = 100

        before_action :set_gift_card, only: [:index, :share_link, :resend]
        before_action :set_load, only: [:share_link, :resend]

        # The recipient sees every load on the card; a sender sees only the
        # loads they paid for.
        def index
          authorize @gift_card, :show?

          scope = @gift_card.loads.in_scope.includes(sender: { avatar_attachment: :blob })
          scope = scope.where(sender_id: current_user.id) unless @gift_card.recipient_id == current_user.id || current_user.admin?
          scope = scope.reorder(created_at: :desc, id: :desc)

          render_page(scope, key: :loads, view: :card, extra: { gift_card_id: @gift_card.id })
        end

        # role=sent (the only role today): my purchases, newest first.
        def sent
          role = params[:role].presence || "sent"
          unless role == "sent"
            return render_error(code: "invalid_parameters", message: "role must be 'sent'", status: :unprocessable_entity)
          end

          scope = GiftCardLoad.in_scope
                              .where(sender_id: current_user.id)
                              .includes(:sender, gift_card: [:recipient, :loads, { merchant: { logo_attachment: :blob } }])
                              .order(created_at: :desc, id: :desc)

          render_page(scope, key: :loads, view: :sent, extra: { role: role })
        end

        def share_link
          authorize @load, :share?
          render_share_link(@load)
        end

        def resend
          authorize @load, :resend?
          render_resend(@load)
        end

        private

        def set_gift_card
          @gift_card = policy_scope(GiftCard).not_merged.find(params[:gift_card_id])
        end

        def set_load
          @load = @gift_card.loads.in_scope.find(params[:id])
        end

        def render_page(scope, key:, view:, extra: {})
          page = [params[:page].to_i, 1].max
          per_page = params[:per_page].to_i
          per_page = PER_PAGE unless per_page.between?(1, MAX_PER_PAGE)
          total = scope.count
          records = scope.offset((page - 1) * per_page).limit(per_page)

          render_success(data: extra.merge(
            key => records.map { |l| GiftCardLoadSerializer.call(l, attachment_url: method(:attachment_url), view: view) },
            page: page,
            per_page: per_page,
            total_count: total,
            has_more: page * per_page < total
          ))
        end
      end
    end
  end
end
