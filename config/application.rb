require_relative "boot"

require "rails"
require File.expand_path("../lib/request_metrics", __dir__)
require File.expand_path("../lib/request_metrics_middleware", __dir__)
require_relative "cloudflare_ips"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_mailbox/engine"
require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module RemMvp
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 7.2

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Resolve request.remote_ip to the real client behind Cloudflare (see
    # config/cloudflare_ips.rb). Rack::Request#ip, used by Rack::Attack, is
    # configured to match in config/initializers/client_ip.rb.
    config.action_dispatch.trusted_proxies =
      ActionDispatch::RemoteIp::TRUSTED_PROXIES + CloudflareIps::RANGES

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Don't generate system test files.
    config.generators.system_tests = nil

    # Request baseline metrics for critical paths (query count, slow queries, timing)
    config.middleware.use RequestMetricsMiddleware

    # Configure Rack::Attack
    config.middleware.use Rack::Attack

    # Compression fallback when requests bypass CDN compression.
    config.middleware.use Rack::Deflater
  end
end
