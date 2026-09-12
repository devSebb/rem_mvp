# Platform-wide gift card browser (RELOADABLE_CARD_PLAN.md §9): one row per
# card, the loads ("Recargas") and the full ledger trail on the detail page.
# Money movements stay in their own controllers (Admin::RefundsController,
# Admin::HoldsController); the card actions here only flip status.
class Admin::GiftCardsController < Admin::BaseController
  PER_PAGE = 25
  FILTERS = %w[all active frozen canceled with_held with_disputed zero_balance].freeze
  # Old links / bookmarks.
  FILTER_ALIASES = { "held" => "with_held", "disputed" => "with_disputed", "redeemed" => "zero_balance" }.freeze

  before_action :set_gift_card, only: [:show, :freeze, :unfreeze, :cancel]

  def index
    @filter = FILTER_ALIASES.fetch(params[:filter].to_s, params[:filter].to_s)
    @filter = "all" unless FILTERS.include?(@filter)
    scope = filtered(GiftCard.not_merged, @filter)

    @query = params[:q].to_s.strip
    scope = scope.merge(search_conditions(@query)) if @query.present?

    @status_counts = FILTERS.index_with { |f| filtered(GiftCard.not_merged, f).count }

    @total_count = scope.count
    @page = [params[:page].to_i, 1].max
    @total_pages = [(@total_count.to_f / PER_PAGE).ceil, 1].max
    @gift_cards = scope.includes(:recipient, :merchant, :loads)
                       .order(created_at: :desc)
                       .offset((@page - 1) * PER_PAGE)
                       .limit(PER_PAGE)
  end

  def show
    @balances = @gift_card.balances
    @loads = @gift_card.loads.includes(:sender, :hold_released_by).fifo.to_a
    @transactions = @gift_card.transactions
                              .includes(:merchant, :user, :gift_card_load, redemption_allocations: :gift_card_load)
                              .order(created_at: :desc, id: :desc)
    @total_redeemed = @gift_card.total_redemptions
    @total_reversed = @gift_card.transactions.successful.reversals.sum(:amount)
    @net_redeemed = @total_redeemed - @total_reversed
    @stripe_refunded_cents = @loads.sum(&:refunded_cents)
    @written_off_cents = @loads.sum(&:written_off_cents)
  end

  # ── Card actions (§5.8, §9): admin-only, status only, never money ─────

  def freeze
    reason = params[:reason].to_s.strip
    if reason.blank?
      redirect_to admin_gift_card_path(@gift_card), alert: "Indica el motivo para congelar la tarjeta." and return
    end
    unless @gift_card.active?
      redirect_to admin_gift_card_path(@gift_card), alert: "Solo se puede congelar una tarjeta activa." and return
    end

    @gift_card.with_lock do
      @gift_card.update!(status: :frozen_by_admin, frozen_at: Time.current, frozen_reason: reason)
    end
    Rails.logger.warn "[CardFreeze] admin_user_id=#{current_user.id} gift_card_id=#{@gift_card.id} reason=#{reason.inspect}"
    redirect_to admin_gift_card_path(@gift_card), notice: "Tarjeta ##{@gift_card.id} congelada. No acepta canjes ni recargas hasta descongelarla."
  end

  def unfreeze
    unless @gift_card.frozen_by_admin?
      redirect_to admin_gift_card_path(@gift_card), alert: "Esta tarjeta no está congelada." and return
    end

    @gift_card.with_lock do
      @gift_card.update!(status: :active, frozen_at: nil)
    end
    Rails.logger.warn "[CardUnfreeze] admin_user_id=#{current_user.id} gift_card_id=#{@gift_card.id}"
    redirect_to admin_gift_card_path(@gift_card), notice: "Tarjeta ##{@gift_card.id} descongelada."
  end

  # Cancel only at zero balance (§5.8): money never disappears by a status
  # flip — refund or write it off first.
  def cancel
    reason = params[:reason].to_s.strip
    if reason.blank?
      redirect_to admin_gift_card_path(@gift_card), alert: "Indica el motivo para cancelar la tarjeta." and return
    end
    if @gift_card.canceled?
      redirect_to admin_gift_card_path(@gift_card), alert: "Esta tarjeta ya está cancelada." and return
    end

    canceled = false
    @gift_card.with_lock do
      @gift_card.reload
      if @gift_card.remaining_balance.to_i.zero?
        @gift_card.update!(status: :canceled, frozen_reason: reason)
        canceled = true
      end
    end

    if canceled
      Rails.logger.warn "[CardCancel] admin_user_id=#{current_user.id} gift_card_id=#{@gift_card.id} reason=#{reason.inspect}"
      redirect_to admin_gift_card_path(@gift_card), notice: "Tarjeta ##{@gift_card.id} cancelada."
    else
      redirect_to admin_gift_card_path(@gift_card),
                  alert: "Solo se puede cancelar una tarjeta con saldo cero. Reembolsa o anula el saldo primero."
    end
  end

  private

  def set_gift_card
    @gift_card = GiftCard.includes(:recipient, :merchant).find(params[:id])
  end

  def filtered(scope, filter)
    case filter
    when "active" then scope.active
    when "frozen" then scope.frozen_by_admin
    when "canceled" then scope.canceled
    when "with_held" then scope.currently_held
    when "with_disputed" then scope.disputed
    when "zero_balance" then scope.where(remaining_balance: 0).where.not(status: GiftCard.statuses[:canceled])
    else scope
    end
  end

  # Card codes are stored hashed, so free text matches everything *around*
  # the card instead: buyer (any load's sender) / recipient (name, email,
  # phone), merchant name, any load's Stripe payment intent — plus the
  # REM-XXXXXX display ref or numeric id.
  def search_conditions(query)
    like = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
    user_ids = User.where("email ILIKE :q OR name ILIKE :q OR phone ILIKE :q", q: like).select(:id)
    merchant_ids = Merchant.where("store_name ILIKE :q", q: like).select(:id)
    load_card_ids = GiftCardLoad.where("payment_intent_id ILIKE :q", q: like)
                                .or(GiftCardLoad.where(sender_id: user_ids))
                                .select(:gift_card_id)

    conditions = GiftCard.where(id: load_card_ids)
                         .or(GiftCard.where(recipient_id: user_ids))
                         .or(GiftCard.where(merchant_id: merchant_ids))

    if (id_ref = query[/\A(?:rem-?)?(\d{1,12})\z/i, 1])
      conditions = conditions.or(GiftCard.where("CAST(gift_cards.id AS TEXT) LIKE ?", "%#{id_ref}"))
    end

    conditions
  end
end
