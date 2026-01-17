class HomeController < ApplicationController
  def index
      @recent_gift_cards = current_user.received_gift_cards.includes(:sender, :merchant).limit(5)
  end
end
