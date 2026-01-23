class HomeController < ApplicationController
  def index
    if user_signed_in? && !current_user.admin?
      @recent_gift_cards = current_user.received_gift_cards.includes(:sender, :merchant).limit(5)
      @merchants = Merchant.active.includes(logo_attachment: :blob).order(:store_name).limit(8)
    end
  end
end
