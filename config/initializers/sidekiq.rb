require 'sidekiq/web'

redis_url = ENV['REDIS_URL']

if Rails.env.production? && redis_url.blank?
  raise "REDIS_URL is required in production for Sidekiq"
end

# Allow localhost fallback only outside production to keep dev/test simple.
redis_url ||= 'redis://localhost:6379/0'

Sidekiq.configure_server do |config|
  config.redis = { url: redis_url }
end

Sidekiq.configure_client do |config|
  config.redis = { url: redis_url }
end

# Ensure Sidekiq is properly loaded for ActiveJob
require 'sidekiq/rails'
