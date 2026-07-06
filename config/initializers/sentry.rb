# Sentry error reporting (sentry-ruby / sentry-rails / sentry-sidekiq).
#
# Fully dormant unless SENTRY_DSN is set: Sentry.init is never called without
# it, and every Sentry.* API (capture_exception, etc.) is a documented no-op
# when the SDK is uninitialized. The app behaves identically without a DSN.
if ENV["SENTRY_DSN"].present?
  Sentry.init do |config|
    config.dsn = ENV["SENTRY_DSN"]
    config.environment = Rails.env
    config.breadcrumbs_logger = [:active_support_logger, :http_logger]

    # Fintech app: never send PII. With send_default_pii = false the SDK does
    # not attach request bodies/params, cookies, user IPs, or auth headers to
    # events. Additionally, sentry-rails applies
    # Rails.application.config.filter_parameters to ActiveSupport breadcrumb
    # payloads automatically (Sentry::Rails::LogSubscribers::ParameterFilter),
    # so a custom before_send scrubber would only duplicate that and is
    # intentionally omitted.
    config.send_default_pii = false

    # Performance tracing off by default; opt in via env var (e.g. "0.1").
    config.traces_sample_rate = ENV.fetch("SENTRY_TRACES_SAMPLE_RATE", "0").to_f
  end
end
