require "digest"

class Rack::Attack
  redis_url = ENV["REDIS_URL"]
  if Rails.env.production?
    raise "REDIS_URL is required in production for Rack::Attack cache" if redis_url.blank?
  else
    redis_url ||= "redis://localhost:6379/0"
  end

  # Configure cache store
  Rack::Attack.cache.store = ActiveSupport::Cache::RedisCacheStore.new(url: redis_url)

  # NOTE: req.ip is the real client only because of config/initializers/client_ip.rb
  # (Cloudflare edges trusted, `Forwarded` header ignored). Without it every
  # throttle below would be keyed on a shared Cloudflare edge address.

  # Normalized email submitted to an auth endpoint, from a form
  # (user[email] / email) or a JSON body ({"email": ...}). Used for per-account
  # throttles that hold even when an attacker rotates IPs.
  def self.submitted_email(req)
    email =
      begin
        req.params.dig("user", "email") || req.params["email"]
      rescue StandardError
        nil
      end

    if email.blank? && req.media_type == "application/json" && (input = req.body)
      begin
        raw = input.read(16 * 1024)
        parsed = JSON.parse(raw.to_s)
        email = parsed["email"] if parsed.is_a?(Hash)
      rescue StandardError
        email = nil
      ensure
        input.rewind if input.respond_to?(:rewind)
      end
    end

    email.to_s.downcase.gsub(/\s+/, "").presence
  end

  # Unauthenticated Active Storage direct uploads: nothing in the web app or
  # the mobile app uses them (uploads go through authenticated controllers),
  # but Rails mounts the route by default, letting anyone with a CSRF token
  # from a public page write arbitrary objects into the storage bucket.
  blocklist("active_storage/direct_uploads") do |req|
    req.path.start_with?("/rails/active_storage/direct_uploads")
  end

  # ── Web (Devise / marketing) ────────────────────────────────────────────

  throttle("web/signup/ip", limit: 5, period: 1.hour) do |req|
    req.ip if req.path == "/users" && req.post?
  end

  # Account deletion now requires the password; cap guessing.
  throttle("web/account_delete/ip", limit: 5, period: 1.hour) do |req|
    req.ip if req.path == "/users" && req.delete?
  end

  # Reset-instructions emails: per IP and per target address (email bombing).
  throttle("web/password_reset/ip", limit: 5, period: 1.hour) do |req|
    req.ip if req.path == "/users/password" && req.post?
  end

  throttle("web/password_reset/email", limit: 3, period: 1.hour) do |req|
    submitted_email(req) if req.path == "/users/password" && req.post?
  end

  # Submitting the new password with a reset token.
  throttle("web/password_update/ip", limit: 10, period: 1.hour) do |req|
    req.ip if req.path == "/users/password" && (req.put? || req.patch?)
  end

  # Contact form emails the team inbox.
  throttle("web/contact/ip", limit: 5, period: 1.hour) do |req|
    req.ip if req.path == "/contact" && req.post?
  end

  # ── Mobile API auth ─────────────────────────────────────────────────────

  # The mobile claim flow re-POSTs signup for both "resend code" and each code
  # submission (auto-submitted on the 6th digit), so a real recipient can use
  # ~5 calls in one claim. 10/hour leaves headroom; 6-digit codes stay unguessable.
  throttle("api/auth/signup/email", limit: 10, period: 1.hour) do |req|
    submitted_email(req) if req.path == "/api/v1/auth/signup" && req.post?
  end

  throttle("api/auth/login/email", limit: 10, period: 10.minutes) do |req|
    submitted_email(req) if req.path == "/api/v1/auth/login" && req.post?
  end

  throttle("api/auth/forgot_password/ip", limit: 5, period: 1.hour) do |req|
    req.ip if req.path == "/api/v1/auth/forgot_password" && req.post?
  end

  throttle("api/auth/forgot_password/email", limit: 3, period: 1.hour) do |req|
    submitted_email(req) if req.path == "/api/v1/auth/forgot_password" && req.post?
  end

  throttle("api/auth/reset_password/ip", limit: 10, period: 1.hour) do |req|
    req.ip if req.path == "/api/v1/auth/reset_password" && req.post?
  end

  # Email OTP: the model caps attempts per code, these cap codes-per-hour and
  # guessing across code reissues.
  throttle("api/auth/verify_email/ip", limit: 20, period: 10.minutes) do |req|
    req.ip if req.path == "/api/v1/auth/verify_email" && req.post?
  end

  throttle("api/auth/verify_email/email", limit: 10, period: 1.hour) do |req|
    submitted_email(req) if req.path == "/api/v1/auth/verify_email" && req.post?
  end

  throttle("api/auth/resend_verification/ip", limit: 5, period: 1.hour) do |req|
    req.ip if req.path == "/api/v1/auth/resend_verification" && req.post?
  end

  throttle("api/auth/resend_verification/email", limit: 3, period: 1.hour) do |req|
    submitted_email(req) if req.path == "/api/v1/auth/resend_verification" && req.post?
  end

  # Account deletion requires the password; cap guessing with a stolen token.
  throttle("api/me/delete/ip", limit: 5, period: 1.hour) do |req|
    req.ip if req.path == "/api/v1/me" && req.delete?
  end

  # ── Merchant POS API lookups (bearer secret) ────────────────────────────

  MERCHANT_LOOKUP = %r{\A/api/v1/gift_cards/(validate|[^/]+)\z}

  throttle("api/merchant_lookup/ip", limit: 60, period: 1.minute) do |req|
    req.ip if req.path.match?(MERCHANT_LOOKUP) && (req.get? || req.post?)
  end

  throttle("api/merchant_lookup/merchant_secret", limit: 120, period: 1.minute) do |req|
    next unless req.path.match?(MERCHANT_LOOKUP) && (req.get? || req.post?)

    scheme, secret = req.get_header("HTTP_AUTHORIZATION").to_s.split(" ", 2)
    Digest::SHA256.hexdigest(secret) if scheme == "Bearer" && secret.present?
  end

  # Throttle POST requests to merchant redemptions by IP
  throttle("merchant/redemptions/ip", limit: 10, period: 1.minute) do |req|
    if req.path == "/merchant/redemptions" && req.post?
      req.ip
    end
  end

  # Throttle merchant POS/API redemption attempts by IP and by presented secret.
  throttle("api/redemptions/ip", limit: 30, period: 1.minute) do |req|
    if req.path == "/api/v1/redemptions" && req.post?
      req.ip
    end
  end

  throttle("api/redemptions/merchant_secret", limit: 60, period: 1.minute) do |req|
    next unless req.path == "/api/v1/redemptions" && req.post?

    scheme, secret = req.get_header("HTTP_AUTHORIZATION").to_s.split(" ", 2)
    Digest::SHA256.hexdigest(secret) if scheme == "Bearer" && secret.present?
  end

  # Throttle webhook requests by IP
  throttle("webhooks/stripe/ip", limit: 60, period: 1.minute) do |req|
    if req.path == "/webhooks/stripe" && req.post?
      req.ip
    end
  end

  # Throttle Twilio webhook requests by IP
  throttle("webhooks/twilio/ip", limit: 100, period: 1.minute) do |req|
    if req.path == "/webhooks/twilio_status" && req.post?
      req.ip
    end
  end

  # Throttle login attempts by IP
  throttle("login/ip", limit: 5, period: 20.minutes) do |req|
    if req.path == "/users/sign_in" && req.post?
      req.ip
    end
  end

  # Throttle signups by IP. Also caps how fast an attacker can trigger
  # claim-verification OTP sends or brute-force claim codes via signup.
  throttle("api/auth/signup/ip", limit: 15, period: 1.hour) do |req|
    if req.path == "/api/v1/auth/signup" && req.post?
      req.ip
    end
  end

  throttle("api/auth/login/ip", limit: 10, period: 10.minutes) do |req|
    if req.path == "/api/v1/auth/login" && req.post?
      req.ip
    end
  end

  # Refresh tokens are 256-bit, so this only guards against abuse/cost. Kept
  # generous because mobile carriers put many real users behind one NAT IP,
  # and a 429 here can sign the app out.
  throttle("api/auth/refresh/ip", limit: 120, period: 30.minutes) do |req|
    if req.path == "/api/v1/auth/refresh" && req.post?
      req.ip
    end
  end

  throttle("api/me/redemption_token/ip", limit: 20, period: 5.minutes) do |req|
    if req.path =~ %r{\A/api/v1/me/gift_cards/\d+/redemption_token\z} && req.post?
      req.ip
    end
  end

  # Claim-link teaser lookups (public, unauthenticated): caps token guessing.
  # Tokens are 128-bit HMACs so guessing is hopeless anyway; this just keeps
  # scanners from hammering the endpoint.
  throttle("api/claim_link/ip", limit: 30, period: 5.minutes) do |req|
    if req.path.start_with?("/api/v1/claim/") && req.get?
      req.ip
    end
  end

  # Same for the public claim web page.
  throttle("web/claim/ip", limit: 60, period: 5.minutes) do |req|
    if req.path.start_with?("/claim/") && req.get?
      req.ip
    end
  end

  # Sender-side share/resend. Resend also has per-card service-level limits
  # (GiftCards::ResendDelivery); this adds a per-IP backstop.
  throttle("api/me/share_link/ip", limit: 30, period: 5.minutes) do |req|
    if req.path =~ %r{\A/api/v1/me/gift_cards/\d+(/loads/\d+)?/share_link\z} && req.post?
      req.ip
    end
  end

  throttle("api/me/resend/ip", limit: 10, period: 5.minutes) do |req|
    if req.path =~ %r{\A/api/v1/me/gift_cards/\d+(/loads/\d+)?/resend\z} && req.post?
      req.ip
    end
  end

  # Throttle login attempts by email
  throttle("login/email", limit: 5, period: 20.minutes) do |req|
    if req.path == "/users/sign_in" && req.post? && req.params["user"]
      req.params["user"]["email"].to_s.downcase.gsub(/\s+/, "")
    end
  end

  # Block requests from known bad IPs (optional)
  # blocklist('block bad IPs') do |req|
  #   # Add IP blocking logic here if needed
  # end

  # Allow requests from localhost in development only. Never in production:
  # a spoofed client IP of 127.0.0.1 would otherwise skip every throttle.
  # (The direct-uploads blocklist still applies locally so dev matches prod.)
  safelist("allow localhost") do |req|
    !Rails.env.production? &&
      !req.path.start_with?("/rails/active_storage/direct_uploads") &&
      ("127.0.0.1" == req.ip || "::1" == req.ip)
  end
end

# 429 body. API clients (the mobile app) render `error.message` from the
# standard { error: { code, message } } envelope; the gem's default plain-text
# "Retry later" left the app showing a generic "try again" that invited
# immediate retries. The code must NOT start with "auth." — the app treats
# auth.* errors as an invalid session and signs the user out.
Rack::Attack.throttled_responder = lambda do |req|
  match = req.env["rack.attack.match_data"] || {}
  period = match[:period].to_i
  retry_after = period.positive? ? period - ((match[:epoch_time] || Time.now.to_i) % period) : 60
  message = "Demasiados intentos. Espera unos minutos e inténtalo de nuevo."
  headers = { "retry-after" => retry_after.to_s }

  if req.path.start_with?("/api/")
    body = { error: { code: "rate_limited", message: message, details: { retry_after_seconds: retry_after } } }
    [ 429, headers.merge("content-type" => "application/json; charset=utf-8"), [ body.to_json ] ]
  else
    [ 429, headers.merge("content-type" => "text/plain; charset=utf-8"), [ "#{message}\n" ] ]
  end
end

# Log blocked requests
ActiveSupport::Notifications.subscribe("rack.attack") do |name, start, finish, request_id, payload|
  req = payload[:request]
  Rails.logger.warn "[Rack::Attack] #{req.ip} #{req.request_method} #{req.fullpath} - #{payload[:match_discriminator]}"
end
