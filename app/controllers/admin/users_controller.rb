# Read-only customer management: search and inspect consumer accounts.
# Mutations (refunds, holds) live in their own controllers; account edits
# stay out of scope until there's an audit log to record them.
class Admin::UsersController < Admin::BaseController
  PER_PAGE = 50
  FILTERS = %w[all claimed pending deleted].freeze

  def index
    scope = User.where(role: :user)

    @filter = FILTERS.include?(params[:filter]) ? params[:filter] : "all"
    scope =
      case @filter
      when "claimed" then scope.active.where.not(claimed_at: nil)
      when "pending" then scope.active.where(claimed_at: nil)
      when "deleted" then scope.where.not(deleted_at: nil)
      else scope
      end

    @query = params[:q].to_s.strip
    if @query.present?
      like = "%#{ActiveRecord::Base.sanitize_sql_like(@query)}%"
      scope = scope.where(
        "email ILIKE :q OR phone ILIKE :q OR name ILIKE :q OR national_id ILIKE :q",
        q: like
      )
    end

    @total_count = scope.count
    @page = [params[:page].to_i, 1].max
    @total_pages = [(@total_count.to_f / PER_PAGE).ceil, 1].max
    @users = scope.order(created_at: :desc)
                  .includes(:received_gift_cards, :sent_gift_cards)
                  .offset((@page - 1) * PER_PAGE)
                  .limit(PER_PAGE)
  end

  def show
    @user = User.find(params[:id])
    @sent_gift_cards = @user.sent_gift_cards.includes(:merchant, :recipient).order(created_at: :desc).limit(5)
    @received_gift_cards = @user.received_gift_cards.includes(:merchant, :sender).order(created_at: :desc).limit(5)
    @recent_transactions = Transaction.where(user_id: @user.id).includes(:merchant).order(created_at: :desc).limit(10)
    @active_sessions_count = UserSession.where(user_id: @user.id, revoked_at: nil).count
    @push_tokens_count = @user.push_tokens.where(active: true).count
    @balance_cents = @user.received_gift_cards.active.sum(:remaining_balance)
  end
end
