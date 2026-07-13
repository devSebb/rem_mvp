# Web fallbacks for the app's universal links (papayal.app/claim/…, /reset).
# When the app is installed the OS opens it directly and these pages are never
# seen; without the app they show the gift (or reset instructions) and funnel
# the visitor to the app download. Fully public — consumers cannot sign in on
# web, and these pages never expose codes or personal data beyond the teaser.
class AppLinksController < ApplicationController
  skip_before_action :authenticate_user!
  layout "marketing"

  def claim
    @gift_card = GiftCards::ClaimLink.find_by_token(params[:token])
    @download_url = AppLinks.download_url
    # Best-effort "open in app" for the pasted-into-browser case, where
    # universal links don't trigger even with the app installed.
    @app_scheme_url = "papayal://claim/#{ERB::Util.url_encode(params[:token].to_s)}"
  end

  def reset
    @download_url = AppLinks.download_url
    @app_scheme_url = "papayal://reset?token=#{ERB::Util.url_encode(params[:token].to_s)}" if params[:token].present?
  end
end
