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

  # Handles the public contact form. Delivers the message to the Papayal
  # inbox (hola@papayal.app) and answers the fetch() call from the
  # marketing Stimulus controller with a small JSON payload.
  def submit_contact
    name = params[:name].to_s.strip
    email = params[:email].to_s.strip
    message = params[:message].to_s.strip

    if name.blank? || email.blank? || message.blank?
      render json: { error: "missing_fields" }, status: :unprocessable_entity
      return
    end

    ContactMailer.contact_message(name, email, message).deliver_later
    render json: { ok: true }
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
