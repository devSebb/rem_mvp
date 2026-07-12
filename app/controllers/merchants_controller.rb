class MerchantsController < ApplicationController
  include ConsumerWebGate

  before_action :authenticate_user!

  def show
    @merchant = Merchant.includes(logo_attachment: :blob).find(params[:id])

    # Return 404 for inactive merchants to non-admin users (reduces enumeration)
    unless current_user.admin? || @merchant.active?
      raise ActiveRecord::RecordNotFound, "Merchant not found"
    end
  end
end
