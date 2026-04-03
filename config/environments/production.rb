require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot.
  config.eager_load = true

  # Full error reports are disabled and caching is turned on.
  config.consider_all_requests_local = false
  config.action_controller.perform_caching = true

  # Ensures that a master key has been made available in ENV["RAILS_MASTER_KEY"], config/master.key, or an environment
  # key such as config/credentials/production.key.
  config.require_master_key = true

  # Do not fall back to assets pipeline if a precompiled asset is missed.
  config.assets.compile = false

  # Allow browsers and CDNs to cache static assets aggressively.
  config.public_file_server.headers = {
    "Cache-Control" => "public, max-age=#{1.year.to_i}, immutable"
  }

  # Specifies the header that your server uses for sending files.
  # config.action_dispatch.x_sendfile_header = "X-Sendfile" # for Apache
  # config.action_dispatch.x_sendfile_header = "X-Accel-Redirect" # for NGINX

  # ---------------------------------------------------------------------------
  # Active Storage service selection (Production)
  #
  # Priority:
  # 1) ACTIVE_STORAGE_SERVICE (explicit override, e.g. "cloudflare_r2", "amazon", "local")
  # 2) Cloudflare R2 if all required R2_* env vars are present
  # 3) Amazon S3 if all required AWS_* env vars are present
  # 4) Fallback to local (not recommended for production)
  #
  # Cloudflare R2 - Required env vars:
  #   R2_BUCKET, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ENDPOINT
  #
  # Amazon S3 - Minimum required env vars for auto-selection:
  #   AWS_S3_BUCKET, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
  # Optional:
  #   AWS_REGION (defaults to us-east-1 in storage.yml)
  #   AWS_S3_ENDPOINT (only for S3-compatible services like MinIO)
  #   AWS_S3_FORCE_PATH_STYLE (set to "true" only if needed for compatibility)
  # ---------------------------------------------------------------------------
  requested_service = ENV["ACTIVE_STORAGE_SERVICE"].presence

  inferred_service =
    if requested_service.present?
      requested_service
    elsif %w[R2_BUCKET R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT].all? { |k| ENV[k].present? }
      "cloudflare_r2"
    elsif %w[AWS_S3_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY].all? { |k| ENV[k].present? }
      "amazon"
    else
      "local"
    end

  config.active_storage.service = inferred_service.to_sym

  # Fail loudly only when the service was explicitly requested; otherwise warn + fallback.
  case config.active_storage.service
  when :cloudflare_r2
    required_env = %w[R2_BUCKET R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT]
    missing = required_env.select { |key| ENV[key].blank? }

    if missing.any?
      if requested_service == "cloudflare_r2"
        raise "Missing required Cloudflare R2 environment variables: #{missing.join(', ')}"
      else
        Rails.logger.warn("R2 env vars missing (#{missing.join(', ')}); falling back to :local for Active Storage")
        config.active_storage.service = :local
      end
    end
  when :amazon
    required_env = %w[AWS_S3_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY]
    missing = required_env.select { |key| ENV[key].blank? }

    if missing.any?
      if requested_service == "amazon"
        raise "Missing required AWS S3 environment variables: #{missing.join(', ')}"
      else
        Rails.logger.warn("AWS S3 env vars missing (#{missing.join(', ')}); falling back to :local for Active Storage")
        config.active_storage.service = :local
      end
    end
  end

  # Mount Action Cable outside main process or domain.
  # config.action_cable.mount_path = nil

  # Force all access to the app over SSL.
  config.force_ssl = true

  # Log to STDOUT by default
  config.logger = ActiveSupport::Logger.new(STDOUT)
    .tap  { |logger| logger.formatter = ::Logger::Formatter.new }
    .then { |logger| ActiveSupport::TaggedLogging.new(logger) }

  # Prepend all log lines with the following tags.
  config.log_tags = [ :request_id ]

  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Use a different cache store in production.
  config.cache_store = :redis_cache_store, {
    url: ENV["REDIS_URL"],
    namespace: "rem_mvp:cache",
    reconnect_attempts: 2,
    connect_timeout: 2,
    read_timeout: 2,
    write_timeout: 2
  }

  # Use a real queuing backend for Active Job.
  config.active_job.queue_adapter = :sidekiq

  config.action_mailer.perform_caching = false
  config.action_mailer.raise_delivery_errors = true
  config.action_mailer.default_url_options = {
    host: ENV["APP_HOST"] || "rem.com",
    protocol: "https"
  }

  # ---------------------------------------------------------------------------
  # URL Generation for ActiveStorage and Controllers
  #
  # Required env vars for correct absolute URLs:
  #   APP_HOST - The production hostname (e.g., "papayal.app")
  # Optional:
  #   APP_PROTOCOL - Defaults to "https"
  #
  # Without APP_HOST, ActiveStorage URLs (logos, avatars) will use the fallback
  # domain which may be incorrect.
  # ---------------------------------------------------------------------------
  config.action_controller.default_url_options = {
    host: ENV["APP_HOST"] || "rem.com",
    protocol: ENV["APP_PROTOCOL"] || "https"
  }

  # Warn if APP_HOST is missing (URLs will be broken)
  if ENV["APP_HOST"].blank?
    Rails.logger.warn("[CONFIG] APP_HOST is not set; ActiveStorage URLs may be incorrect in production")
  end

  config.i18n.fallbacks = true
  config.active_support.report_deprecations = false
  config.active_record.dump_schema_after_migration = false
  config.active_record.attributes_for_inspect = [ :id ]
end
