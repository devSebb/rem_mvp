class Merchant::DashboardController < ApplicationController
  before_action :ensure_merchant

  def index
    @merchant = current_user.merchant
    
    # Get all redemption transactions REDEEMED BY this merchant (redeemer-paid model)
    # This now correctly shows redemptions performed by this merchant, not cards issued by them.
    @redemption_transactions = Transaction.where(merchant: @merchant)
                                        .where(txn_type: :redemption, status: :succeeded)
                                        .includes(gift_card: [:sender, :recipient, :merchant])
    
    # Today's redemptions (count of transactions, not gift cards)
    @today_redemptions = @redemption_transactions.where(created_at: Date.current.all_day).count

    # Pending settlement: redemptions not yet covered by any settlement,
    # net of reversals — the same math the admin payout flow uses. (This
    # was previously lifetime gross: it never dropped after a payout and
    # never subtracted reversed redemptions.)
    @pending_settlement = @merchant.unsettled_net_redeemed_cents

    # Recent redemptions (transactions, not gift cards)
    @recent_redemptions = @redemption_transactions.order(created_at: :desc).limit(10)

    # Lifetime redeemed, net of reversals; reversed total shown alongside.
    @total_reversed_amount = Transaction.successful.reversals.where(merchant_id: @merchant.id).sum(:amount)
    @total_redemption_amount = @redemption_transactions.sum(:amount) - @total_reversed_amount
    @unique_gift_cards_redeemed = @redemption_transactions.select(:gift_card_id).distinct.count
  end

  private

  def ensure_merchant
    unless current_user&.merchant?
      flash[:alert] = 'You must be a merchant to access this area.'
      redirect_to root_path
    end
  end
end
