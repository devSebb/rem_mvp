ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

# Safety: if a developer has a global DATABASE_URL set (often pointing at the development DB),
# Rails will merge it into the test config too. That makes `db:test:purge` dangerous because it
# can attempt to drop the dev DB while running specs.
#
# If you want a URL-driven test database, set TEST_DATABASE_URL. Otherwise we force DATABASE_URL
# to a local `rem_mvp_test` URL for test runs so dotenv (or your shell) can't accidentally
# point tests at the dev database.
env_name = ENV["RAILS_ENV"] || ENV["RACK_ENV"]
is_rspec = File.basename($PROGRAM_NAME) == "rspec"
if env_name == "test" || is_rspec
  test_db_url = ENV["TEST_DATABASE_URL"].to_s
  ENV["DATABASE_URL"] = test_db_url.empty? ? "postgresql:///rem_mvp_test" : test_db_url
end

require "bundler/setup" # Set up gems listed in the Gemfile.
require "bootsnap/setup" # Speed up boot time by caching expensive operations.
