class HomeController < ApplicationController
  include ConsumerWebGate

  def index
    # The admin command center lives at /admin now.
    return redirect_to admin_root_path if current_user&.admin?

    if user_signed_in?
      @recent_gift_cards = current_user.received_gift_cards.includes(:sender, :merchant).limit(5)
      @merchants = Merchant.active.includes(logo_attachment: :blob).order(:store_name).limit(8)
    end
  end
end
