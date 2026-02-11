class MarketingController < ApplicationController
  skip_before_action :authenticate_user!
  layout "marketing"

  def landing
    if user_signed_in?
      redirect_to current_user.merchant? ? merchant_root_path : home_path
      return
    end
  end

  def about
  end

  def contact
  end
end
