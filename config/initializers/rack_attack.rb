class Rack::Attack
  # Configure cache store
  Rack::Attack.cache.store = ActiveSupport::Cache::RedisCacheStore.new(url: ENV['REDIS_URL'] || 'redis://localhost:6379/0')

  # Throttle POST requests to merchant redemptions by IP
  throttle('merchant/redemptions/ip', limit: 10, period: 1.minute) do |req|
    if req.path == '/merchant/redemptions' && req.post?
      req.ip
    end
  end

  # Throttle webhook requests by IP
  throttle('webhooks/stripe/ip', limit: 20, period: 1.minute) do |req|
    if req.path == '/webhooks/stripe' && req.post?
      req.ip
    end
  end

  # Throttle login attempts by IP
  throttle('login/ip', limit: 5, period: 20.minutes) do |req|
    if req.path == '/users/sign_in' && req.post?
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
