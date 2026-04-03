# frozen_string_literal: true

# Initializes and clears per-request metrics storage so instrumentation
# can record query count and slow queries for baseline capture.
class RequestMetricsMiddleware
  SKIP_PREFIXES = %w[
    /assets/
    /optimized/
    /icons/
    /landing/
    /mockups/
    /rails/active_storage/
    /up
  ].freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) if skip_request?(env["PATH_INFO"])

    RequestMetrics.init!
    @app.call(env)
  ensure
    RequestMetrics.clear!
  end

  private

  def skip_request?(path)
    return true if path.blank?

    SKIP_PREFIXES.any? { |prefix| path.start_with?(prefix) }
  end
end
