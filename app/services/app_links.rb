# Builds the absolute https://papayal.app URLs that the mobile app claims as
# universal links (see WellKnownController and the app's linking config).
# Centralized so message copy, mailers, and controllers stay consistent.
module AppLinks
  module_function

  def base_url
    host = ENV["APP_HOST"].presence || "localhost:3000"
    # Local .env sets APP_HOST with the scheme included; production sets a
    # bare host + APP_PROTOCOL. Accept both.
    return host.chomp("/") if host.start_with?("http://", "https://")

    protocol = ENV["APP_PROTOCOL"].presence || (Rails.env.production? ? "https" : "http")
    "#{protocol}://#{host}"
  end

  def claim_url(token)
    "#{base_url}/claim/#{token}"
  end

  def reset_url(token)
    "#{base_url}/reset?token=#{CGI.escape(token.to_s)}"
  end

  # Where "download the app" CTAs point. TestFlight today, the App Store
  # listing after launch — swapped via env var, no deploy needed elsewhere.
  def download_url
    ENV["APP_DOWNLOAD_URL"].presence
  end
end
