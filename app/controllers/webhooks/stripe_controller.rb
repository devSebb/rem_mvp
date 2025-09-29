class Webhooks::StripeController < ApplicationController
  skip_before_action :authenticate_user!
  skip_before_action :verify_authenticity_token

  def receive
    payload = request.body.read
    signature = request.headers['Stripe-Signature']

    event = StripeWebhooks.verify_signature(payload, signature)
    
    if event
      StripeWebhooks.process_event(event)
      render json: { status: 'success' }, status: :ok
    else
      Rails.logger.error "Invalid Stripe webhook signature"
      render json: { error: 'Invalid signature' }, status: :bad_request
    end
  rescue => e
    Rails.logger.error "Stripe webhook error: #{e.message}"
    render json: { error: 'Webhook processing failed' }, status: :internal_server_error
  end
end
