class Webhooks::TwilioController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_before_action :authenticate_user!
  before_action :verify_twilio_signature

  def status
    message_sid = params[:MessageSid]
    message_status = params[:MessageStatus]
    error_code = params[:ErrorCode]

    Rails.logger.info "Twilio webhook received: SID=#{message_sid}, Status=#{message_status}, ErrorCode=#{error_code}"

    # You can implement additional logic here to track delivery status
    # For example, update a delivery tracking table or send notifications to admins

    head :ok
  end

  private

  def verify_twilio_signature
    # Skip verification in development for easier testing
    return if Rails.env.development?

    validator = Twilio::Security::RequestValidator.new(
      Rails.application.config.twilio[:auth_token]
    )
    
    signature = request.headers['HTTP_X_TWILIO_SIGNATURE']
    url = request.original_url
    post_params = request.POST
    
    unless validator.validate(url, post_params, signature)
      Rails.logger.warn "Invalid Twilio signature from IP: #{request.ip}"
      render json: { error: 'Invalid signature' }, status: :forbidden
    end
  end
end
