class Merchant::DashboardController < ApplicationController
  before_action :ensure_merchant

  def index
    @merchant = current_user.merchant
    
    # Get all redemption transactions for this merchant
    @redemption_transactions = Transaction.joins(:gift_card)
                                        .where(gift_cards: { merchant: @merchant })
                                        .where(txn_type: :redemption, status: :succeeded)
                                        .includes(gift_card: [:sender, :recipient])
    
    # Today's redemptions (count of transactions, not gift cards)
    @today_redemptions = @redemption_transactions.where(created_at: Date.current.all_day).count
    
    # Pending settlement (sum of all redemption amounts)
    @pending_settlement = @redemption_transactions.sum(:amount)
    
    # Recent redemptions (transactions, not gift cards)
    @recent_redemptions = @redemption_transactions.order(created_at: :desc).limit(10)
    
    # Additional stats for partial redemptions
    @total_redemption_amount = @redemption_transactions.sum(:amount)
    @unique_gift_cards_redeemed = @redemption_transactions.joins(:gift_card).distinct.count('gift_cards.id')
  end

  private

  def ensure_merchant
    unless current_user&.merchant?
      flash[:alert] = 'You must be a merchant to access this area.'
      redirect_to root_path
    end
  end
end
