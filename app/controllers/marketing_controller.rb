class MarketingController < ApplicationController
  skip_before_action :authenticate_user!
  layout "marketing"

  def landing
    if user_signed_in?
      redirect_to signed_in_landing_path
      return
    end
  end

  def about
  end

  def contact
  end

  # Public "coming soon" page: the consumer experience lives in the mobile
  # app, so signed-in shoppers are routed here instead of the web wallet.
  def proximamente
  end

  private

  def signed_in_landing_path
    return merchant_root_path if current_user.merchant?
    return admin_root_path if current_user.admin?

    proximamente_path
  end
end
