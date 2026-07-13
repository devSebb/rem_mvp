require "digest"

class Rack::Attack
  redis_url = ENV['REDIS_URL']
  if Rails.env.production?
    raise "REDIS_URL is required in production for Rack::Attack cache" if redis_url.blank?
  else
    redis_url ||= 'redis://localhost:6379/0'
  end

  # Configure cache store
  Rack::Attack.cache.store = ActiveSupport::Cache::RedisCacheStore.new(url: redis_url)

  # Throttle POST requests to merchant redemptions by IP
  throttle('merchant/redemptions/ip', limit: 10, period: 1.minute) do |req|
    if req.path == '/merchant/redemptions' && req.post?
      req.ip
    end
  end

  # Throttle merchant POS/API redemption attempts by IP and by presented secret.
  throttle('api/redemptions/ip', limit: 30, period: 1.minute) do |req|
    if req.path == '/api/v1/redemptions' && req.post?
      req.ip
    end
  end

  throttle('api/redemptions/merchant_secret', limit: 60, period: 1.minute) do |req|
    next unless req.path == '/api/v1/redemptions' && req.post?

    scheme, secret = req.get_header('HTTP_AUTHORIZATION').to_s.split(' ', 2)
    Digest::SHA256.hexdigest(secret) if scheme == 'Bearer' && secret.present?
  end

  # Throttle webhook requests by IP
  throttle('webhooks/stripe/ip', limit: 60, period: 1.minute) do |req|
    if req.path == '/webhooks/stripe' && req.post?
      req.ip
    end
  end

  # Throttle Twilio webhook requests by IP
  throttle('webhooks/twilio/ip', limit: 100, period: 1.minute) do |req|
    if req.path == '/webhooks/twilio_status' && req.post?
      req.ip
    end
  end

  # Throttle login attempts by IP
  throttle('login/ip', limit: 5, period: 20.minutes) do |req|
    if req.path == '/users/sign_in' && req.post?
      req.ip
    end
  end

  # Throttle signups by IP. Also caps how fast an attacker can trigger
  # claim-verification OTP sends or brute-force claim codes via signup.
  throttle('api/auth/signup/ip', limit: 15, period: 1.hour) do |req|
    if req.path == '/api/v1/auth/signup' && req.post?
      req.ip
    end
  end

  throttle('api/auth/login/ip', limit: 10, period: 10.minutes) do |req|
    if req.path == '/api/v1/auth/login' && req.post?
      req.ip
    end
  end

  throttle('api/auth/refresh/ip', limit: 30, period: 30.minutes) do |req|
    if req.path == '/api/v1/auth/refresh' && req.post?
      req.ip
    end
  end

  throttle('api/me/redemption_token/ip', limit: 20, period: 5.minutes) do |req|
    if req.path =~ %r{\A/api/v1/me/gift_cards/\d+/redemption_token\z} && req.post?
      req.ip
    end
  end

  # Claim-link teaser lookups (public, unauthenticated): caps token guessing.
  # Tokens are 128-bit HMACs so guessing is hopeless anyway; this just keeps
  # scanners from hammering the endpoint.
  throttle('api/claim_link/ip', limit: 30, period: 5.minutes) do |req|
    if req.path.start_with?('/api/v1/claim/') && req.get?
      req.ip
    end
  end

  # Same for the public claim web page.
  throttle('web/claim/ip', limit: 60, period: 5.minutes) do |req|
    if req.path.start_with?('/claim/') && req.get?
      req.ip
    end
  end

  # Sender-side share/resend. Resend also has per-card service-level limits
  # (GiftCards::ResendDelivery); this adds a per-IP backstop.
  throttle('api/me/share_link/ip', limit: 30, period: 5.minutes) do |req|
    if req.path =~ %r{\A/api/v1/me/gift_cards/\d+/share_link\z} && req.post?
      req.ip
    end
  end

  throttle('api/me/resend/ip', limit: 10, period: 5.minutes) do |req|
    if req.path =~ %r{\A/api/v1/me/gift_cards/\d+/resend\z} && req.post?
      req.ip
    end
  end

  # Throttle login attempts by email
  throttle('login/email', limit: 5, period: 20.minutes) do |req|
    if req.path == '/users/sign_in' && req.post? && req.params['user']
      req.params['user']['email'].to_s.downcase.gsub(/\s+/, "")
    end
  end

  # Block requests from known bad IPs (optional)
  # blocklist('block bad IPs') do |req|
  #   # Add IP blocking logic here if needed
  # end

  # Allow requests from localhost in development
  safelist('allow localhost') do |req|
    '127.0.0.1' == req.ip || '::1' == req.ip
  end
end

# Log blocked requests
ActiveSupport::Notifications.subscribe('rack.attack') do |name, start, finish, request_id, payload|
  req = payload[:request]
  Rails.logger.warn "[Rack::Attack] #{req.ip} #{req.request_method} #{req.fullpath} - #{payload[:match_discriminator]}"
end
