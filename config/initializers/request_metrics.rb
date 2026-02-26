# frozen_string_literal: true

# Baseline instrumentation for critical endpoints: request timing, db_runtime,
# view_runtime, query count, and slow query visibility.
# Enable with REQUEST_METRICS_ENABLED=1 in production/staging to capture baselines.
return unless ENV["REQUEST_METRICS_ENABLED"] == "1"

Rails.application.config.after_initialize do
  # Per-request query count and slow query list
  ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, start, finish, _id, payload|
    duration_ms = (finish - start) * 1000
    RequestMetrics.record_query(duration_ms, payload[:sql])
  end

  # Log timing for critical paths (enables baseline p50/p95/p99 via log aggregation)
  ActiveSupport::Notifications.subscribe("process_action.action_controller") do |_name, start, finish, _id, payload|
    path = payload[:path]
    next unless RequestMetrics.critical_path?(path)

    duration_ms = (finish - start) * 1000
    db_runtime = payload[:db_runtime] || 0
    view_runtime = payload[:view_runtime] || 0
    status = payload[:status] || 0
    store = RequestMetrics.store
    query_count = store&.dig(:query_count) || 0
    slow_queries = store&.dig(:slow_queries) || []

    Rails.logger.info(
      "[REQUEST_METRICS] path=#{path} status=#{status} " \
      "duration_ms=#{duration_ms.round(2)} db_ms=#{db_runtime.round(2)} view_ms=#{view_runtime.round(2)} " \
      "query_count=#{query_count}"
    )

    next if slow_queries.empty?

    slow_queries.each do |sq|
      Rails.logger.warn("[REQUEST_METRICS] slow_query path=#{path} ms=#{sq[:ms]} sql=#{sq[:sql].inspect}")
    end
  end
end
