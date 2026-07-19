# Global ledger browser ("Movimientos"): every transaction on the platform,
# filterable by type, status, merchant and date range. Read-only — the
# ledger is the financial source of truth and this is its window.
class Admin::TransactionsController < Admin::BaseController
  PER_PAGE = 50
  TYPE_FILTERS = %w[all purchase redemption refund adjustment issuance].freeze
  STATUS_FILTERS = %w[all succeeded pending failed].freeze

  def index
    scope = Transaction.all

    @type = TYPE_FILTERS.include?(params[:type]) ? params[:type] : "all"
    scope = scope.where(txn_type: @type) unless @type == "all"

    @status = STATUS_FILTERS.include?(params[:status]) ? params[:status] : "all"
    scope = scope.where(status: @status) unless @status == "all"

    @merchant_id = params[:merchant_id].presence&.to_i
    scope = scope.where(merchant_id: @merchant_id) if @merchant_id

    @from = parse_date(params[:from])
    @to = parse_date(params[:to])
    scope = scope.where(created_at: @from.beginning_of_day..) if @from
    scope = scope.where(created_at: ..@to.end_of_day) if @to

    @query = params[:q].to_s.strip
    if @query.present?
      like = "%#{ActiveRecord::Base.sanitize_sql_like(@query)}%"
      scope = scope.where("processor_ref ILIKE :q OR merchant_reference ILIKE :q OR idempotency_key ILIKE :q", q: like)
    end

    @type_counts = Transaction.group(:txn_type).count
    @total_volume_cents = scope.where(status: :succeeded).sum(:amount)

    @total_count = scope.count
    @page = [params[:page].to_i, 1].max
    @total_pages = [(@total_count.to_f / PER_PAGE).ceil, 1].max
    @transactions = scope.includes(:gift_card, :merchant, :user)
                         .order(created_at: :desc, id: :desc)
                         .offset((@page - 1) * PER_PAGE)
                         .limit(PER_PAGE)

    @merchants = Merchant.order(:store_name).pluck(:store_name, :id)
  end

  private

  def parse_date(value)
    return nil if value.blank?

    Date.iso8601(value)
  rescue ArgumentError, Date::Error
    nil
  end
end
