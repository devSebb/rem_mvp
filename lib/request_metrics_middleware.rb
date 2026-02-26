# frozen_string_literal: true

# Initializes and clears per-request metrics storage so instrumentation
# can record query count and slow queries for baseline capture.
class RequestMetricsMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    RequestMetrics.init!
    @app.call(env)
  ensure
    RequestMetrics.clear!
  end
end
