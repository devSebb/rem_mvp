class Webhooks::TwilioController < ApplicationController
  skip_before_action :verify_authenticity_token
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
    # In production, you should verify the Twilio signature
    # For now, we'll skip this for development
    return if Rails.env.development?

    # TODO: Implement Twilio signature verification
    # See: https://www.twilio.com/docs/usage/webhooks/webhooks-security
  end
end
