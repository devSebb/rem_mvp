class Merchant::DashboardController < ApplicationController
  before_action :ensure_merchant

  def index
    @merchant = current_user.merchant
    @today_redemptions = @merchant.gift_cards.redeemed.where(redeemed_at: Date.current.all_day).count
    @pending_settlement = @merchant.gift_cards.redeemed.sum(:amount)
    @recent_redemptions = @merchant.gift_cards.redeemed.includes(:sender, :recipient).order(redeemed_at: :desc).limit(10)
  end

  private

  def ensure_merchant
    unless current_user&.merchant?
      flash[:alert] = 'You must be a merchant to access this area.'
      redirect_to root_path
    end
  end
end
