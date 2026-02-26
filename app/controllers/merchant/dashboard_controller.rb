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
    
    # Pending settlement (sum of all redemption amounts redeemed by this merchant)
    total_redemption_amount = @redemption_transactions.sum(:amount)
    @pending_settlement = total_redemption_amount
    
    # Recent redemptions (transactions, not gift cards)
    @recent_redemptions = @redemption_transactions.order(created_at: :desc).limit(10)
    
    # Additional stats for partial redemptions
    @total_redemption_amount = total_redemption_amount
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
