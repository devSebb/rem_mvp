class Webhooks::StripeController < ApplicationController
  skip_before_action :authenticate_user!
  skip_before_action :verify_authenticity_token

  def receive
    event_id = request.headers["Stripe-Event-Id"] || "unknown"
    payload = request.body.read
    signature = request.headers['Stripe-Signature']

    Rails.logger.info "🔔 Stripe webhook received: #{event_id}"
    
    event = StripeWebhooks.verify_signature(payload, signature)
    
    if event
      Rails.logger.info "✅ Webhook signature verified. Processing event: #{event.type}"
      StripeWebhooks.process_event(event)
      render json: { status: 'success' }, status: :ok
    else
      Rails.logger.error "❌ Invalid Stripe webhook signature. Check STRIPE_WEBHOOK_SECRET env var."
      Rails.logger.error "   Make sure you're running: stripe listen --forward-to http://localhost:3000/webhooks/stripe"
      # A signature failure never succeeds on retry, so Stripe will keep
      # hammering this endpoint for ~3 days and then disable it. Worth knowing
      # on the first occurrence: it means a rotated STRIPE_WEBHOOK_SECRET,
      # clock drift past Stripe's 5-minute tolerance, or someone probing the
      # URL. The payload is deliberately not attached — it is unverified input.
      Sentry.capture_message(
        "Stripe webhook signature verification failed",
        level: :warning,
        tags: { stripe_event_id: event_id }
      )
      render json: { error: 'Invalid signature' }, status: :bad_request
    end
  rescue => e
    Rails.logger.error "💥 Stripe webhook error: #{e.class} - #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    # Without this the backtrace only ever reaches a Render log, which is
    # deleted after 7 days on the Hobby plan. Returning 500 is correct — it
    # makes Stripe retry — but a retry that keeps failing is invisible
    # otherwise. No-op while SENTRY_DSN is unset.
    Sentry.capture_exception(e, tags: { stripe_event_id: event_id })
    render json: { error: 'Webhook processing failed' }, status: :internal_server_error
  end
end
