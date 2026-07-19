# Declined purchase attempts — previously email-only, now listable. A row
# is "resuelto" when the same PaymentIntent later succeeded (buyer retried).
class Admin::PaymentFailuresController < Admin::BaseController
  PER_PAGE = 50
  FILTERS = %w[unresolved resolved all].freeze

  def index
    @filter = FILTERS.include?(params[:filter]) ? params[:filter] : "unresolved"
    scope =
      case @filter
      when "unresolved" then PaymentFailure.unresolved
      when "resolved" then PaymentFailure.where.not(resolved_at: nil)
      else PaymentFailure.all
      end

    @counts = {
      "unresolved" => PaymentFailure.unresolved.count,
      "resolved" => PaymentFailure.where.not(resolved_at: nil).count,
      "all" => PaymentFailure.count
    }
    @lost_volume_cents = PaymentFailure.unresolved.sum(:amount)

    @total_count = scope.count
    @page = [params[:page].to_i, 1].max
    @total_pages = [(@total_count.to_f / PER_PAGE).ceil, 1].max
    @payment_failures = scope.includes(:sender, :merchant)
                             .recent_first
                             .offset((@page - 1) * PER_PAGE)
                             .limit(PER_PAGE)
  end
end
