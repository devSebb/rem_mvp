class HomeController < ApplicationController
  skip_before_action :authenticate_user!, only: [:index]

  def index
    if user_signed_in?
      @recent_gift_cards = current_user.received_gift_cards.includes(:sender, :merchant).limit(5)
    end
  end
end
