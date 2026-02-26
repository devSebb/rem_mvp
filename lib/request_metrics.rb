# frozen_string_literal: true

# Thread-local storage for per-request query count and slow query times.
# Used by RequestMetrics::Instrumentation to log baselines for critical endpoints.
module RequestMetrics
  SLOW_QUERY_MS = (ENV["REQUEST_METRICS_SLOW_QUERY_MS"] || 100).to_i
  CRITICAL_PATHS = [
    "/gift_cards",
    "/gift_cards/success",
    "/gift_cards/checkout",
    "/merchant",
    "/merchant/redemptions",
    "/merchant/settlements",
    "/api/v1/checkout/payment_intent",
    "/api/v1/checkout/validate_kyc",
    "/webhooks/stripe"
  ].freeze

  class << self
    def init!
      self.store = { query_count: 0, slow_queries: [] }
    end

    def clear!
      self.store = nil
    end

    def store
      Thread.current[:request_metrics_store]
    end

    def store=(val)
      Thread.current[:request_metrics_store] = val
    end

    def record_query(duration_ms, sql = nil)
      return unless store

      store[:query_count] += 1
      return if duration_ms < SLOW_QUERY_MS

      store[:slow_queries] << { ms: duration_ms.round(2), sql: sql ? truncate_sql(sql) : nil }
    end

    def critical_path?(path)
      return false if path.blank?

      path = path.split("?").first
      CRITICAL_PATHS.any? { |p| path == p || path.start_with?("#{p}/") || path.start_with?("#{p}.") }
    end

    private

    def truncate_sql(sql, max: 200)
      return nil if sql.blank?

      sql = sql.to_s.strip
      sql.length <= max ? sql : "#{sql[0, max]}..."
    end
  end
end
