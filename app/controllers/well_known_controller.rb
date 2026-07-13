# Serves the platform association files that let iOS (universal links) and
# Android (app links) claim https://papayal.app/* URLs for the mobile app.
# Explicit controller actions (not public/ static files) so the content type
# is guaranteed application/json — Apple's CDN rejects anything else.
class WellKnownController < ApplicationController
  skip_before_action :authenticate_user!

  IOS_APP_ID = "DLFL9SP5JG.com.papayal.app".freeze
  ANDROID_PACKAGE = "com.papayal.app".freeze
  # Paths the app handles. Keep in sync with the mobile linking config
  # (papayal-mobile src/linking) and AppLinks url builders.
  UNIVERSAL_LINK_PATHS = ["/claim/*", "/reset"].freeze

  def apple_app_site_association
    render json: {
      applinks: {
        apps: [],
        details: [
          { appID: IOS_APP_ID, paths: UNIVERSAL_LINK_PATHS }
        ]
      }
    }
  end

  def assetlinks
    # SHA-256 fingerprint(s) of the Android signing cert, comma-separated.
    # From `eas credentials` (Google Play App Signing key once live).
    fingerprints = ENV["ANDROID_CERT_SHA256_FINGERPRINTS"].to_s.split(",").map(&:strip).reject(&:blank?)

    render json: [
      {
        relation: ["delegate_permission/common.handle_all_urls"],
        target: {
          namespace: "android_app",
          package_name: ANDROID_PACKAGE,
          sha256_cert_fingerprints: fingerprints
        }
      }
    ]
  end
end
