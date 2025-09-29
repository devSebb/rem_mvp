class Merchant::SettlementsController < ApplicationController
  before_action :ensure_merchant
  before_action :set_settlement, only: [:show]

  def index
    @settlements = current_user.merchant.settlements.order(created_at: :desc)
  end

  def show
  end

  private

  def ensure_merchant
    unless current_user&.merchant?
      flash[:alert] = 'You must be a merchant to access this area.'
      redirect_to root_path
    end
  end

  def set_settlement
    @settlement = current_user.merchant.settlements.find(params[:id])
  end
end
