# frozen_string_literal: true

# CORS policy: strict in production; permissive only for known local development hosts.
# Credentials are disabled because mobile clients use Authorization bearer tokens
# rather than cookies.
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  dev_origins = [
    %r{\Ahttps?://localhost(:\d+)?\z},
    %r{\Ahttps?://127\.0\.0\.1(:\d+)?\z},
    %r{\Ahttps?://10\.\d{1,3}\.\d{1,3}\.\d{1,3}(:\d+)?\z},
    %r{\Ahttps?://192\.168\.\d{1,3}\.\d{1,3}(:\d+)?\z}
  ]

  env_origins =
    ENV.fetch("CORS_ORIGINS", "")
       .split(/[,\s]+/)
       .map(&:strip)
       .reject(&:empty?)

  fallback_origin = ENV["APP_HOST"].presence

  allowed_origins =
    if Rails.env.development? || Rails.env.test?
      dev_origins
    else
      env_origins.presence || Array(fallback_origin).compact
    end

  if allowed_origins.blank?
    Rails.logger.warn("CORS disabled: no allowed origins configured") if Rails.env.production?
  else
    allow do
      origins(*allowed_origins)

      resource "/api/v1/*",
               headers: %w[
                 Authorization
                 Content-Type
                 Accept
                 Origin
                 User-Agent
                 Access-Control-Request-Method
                 Access-Control-Request-Headers
               ],
               expose: %w[Authorization X-Request-Id],
               methods: %i[get post put patch delete options head],
               credentials: false,
               max_age: 600
    end
  end
end

