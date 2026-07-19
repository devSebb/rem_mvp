# Platform-wide gift card browser: every card as an admin object, with the
# full ledger trail on the detail page. Read-only — money movements stay in
# their own controllers (Admin::RefundsController, Admin::HoldsController).
class Admin::GiftCardsController < Admin::BaseController
  PER_PAGE = 25
  FILTERS = %w[all active redeemed canceled held disputed].freeze

  def index
    scope = GiftCard.all

    @filter = FILTERS.include?(params[:filter]) ? params[:filter] : "all"
    scope =
      case @filter
      when "active" then scope.active
      when "redeemed" then scope.redeemed
      when "canceled" then scope.canceled
      when "held" then scope.currently_held
      when "disputed" then scope.disputed
      else scope
      end

    @query = params[:q].to_s.strip
    scope = scope.merge(search_conditions(@query)) if @query.present?

    @status_counts = {
      "all" => GiftCard.count,
      "active" => GiftCard.active.count,
      "redeemed" => GiftCard.redeemed.count,
      "canceled" => GiftCard.canceled.count,
      "held" => GiftCard.currently_held.count,
      "disputed" => GiftCard.disputed.count
    }

    @total_count = scope.count
    @page = [params[:page].to_i, 1].max
    @total_pages = [(@total_count.to_f / PER_PAGE).ceil, 1].max
    @gift_cards = scope.includes(:sender, :recipient, :merchant)
                       .order(created_at: :desc)
                       .offset((@page - 1) * PER_PAGE)
                       .limit(PER_PAGE)
  end

  def show
    @gift_card = GiftCard.includes(:sender, :recipient, :merchant).find(params[:id])
    @transactions = @gift_card.transactions.includes(:merchant, :user).order(created_at: :desc, id: :desc)
    @total_redeemed = @gift_card.total_redemptions
    @stripe_refunded_cents = @gift_card.transactions.successful.refunds
                                       .where("(metadata ->> 'stripe_refund_id') IS NOT NULL")
                                       .sum(:amount)
  end

  private

  # Card codes are stored hashed, so free text matches everything *around*
  # the card instead: buyer/recipient (name, email, phone), merchant name,
  # Stripe payment intent — plus the REM-XXXXXX display ref or numeric id.
  def search_conditions(query)
    like = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
    user_ids = User.where("email ILIKE :q OR name ILIKE :q OR phone ILIKE :q", q: like).select(:id)
    merchant_ids = Merchant.where("store_name ILIKE :q", q: like).select(:id)

    conditions = GiftCard.where("payment_intent_id ILIKE ?", like)
                         .or(GiftCard.where(sender_id: user_ids))
                         .or(GiftCard.where(recipient_id: user_ids))
                         .or(GiftCard.where(merchant_id: merchant_ids))

    if (id_ref = query[/\A(?:rem-?)?(\d{1,12})\z/i, 1])
      conditions = conditions.or(GiftCard.where("CAST(gift_cards.id AS TEXT) LIKE ?", "%#{id_ref}"))
    end

    conditions
  end
end
