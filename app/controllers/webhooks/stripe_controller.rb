class Webhooks::StripeController < ApplicationController
  skip_before_action :authenticate_user!
  skip_before_action :verify_authenticity_token

  def receive
    payload = request.body.read
    signature = request.headers['Stripe-Signature']

    Rails.logger.info "🔔 Stripe webhook received: #{request.headers['Stripe-Event-Id'] || 'unknown'}"
    
    event = StripeWebhooks.verify_signature(payload, signature)
    
    if event
      Rails.logger.info "✅ Webhook signature verified. Processing event: #{event.type}"
      StripeWebhooks.process_event(event)
      render json: { status: 'success' }, status: :ok
    else
      Rails.logger.error "❌ Invalid Stripe webhook signature. Check STRIPE_WEBHOOK_SECRET env var."
      Rails.logger.error "   Make sure you're running: stripe listen --forward-to http://localhost:3000/webhooks/stripe"
      render json: { error: 'Invalid signature' }, status: :bad_request
    end
  rescue => e
    Rails.logger.error "💥 Stripe webhook error: #{e.class} - #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    render json: { error: 'Webhook processing failed' }, status: :internal_server_error
  end
end
