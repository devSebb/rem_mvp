Rails.application.configure do
  config.stripe = {
    secret_key: ENV['STRIPE_SECRET_KEY'],
    publishable_key: ENV['STRIPE_PUBLISHABLE_KEY'],
    webhook_secret: ENV['STRIPE_WEBHOOK_SECRET']
  }
end

Stripe.api_key = Rails.application.config.stripe[:secret_key]
