module MarketingHelper
  STORE_LINKS = {
    ios: ["PAPAYAL_IOS_STORE_URL", "https://apps.apple.com/us/app/papayal/id6759072681", "apps.apple.com"],
    android: ["PAPAYAL_ANDROID_STORE_URL", "https://play.google.com/store/apps/details?id=com.papayal.app&hl=es", "play.google.com"]
  }.freeze

  # Independent of AppLinks.download_url, which also serves claim/reset flows.
  # An explicitly empty or invalid override disables that platform's links.
  def marketing_store_url(platform, locale: :es)
    key, default, host = STORE_LINKS.fetch(platform)
    value = ENV.fetch(key, default).presence
    return unless value

    uri = URI.parse(value)
    return unless uri.scheme == "https" && uri.host == host && uri.userinfo.nil?

    if platform == :android
      query = URI.decode_www_form(uri.query.to_s).to_h
      query["hl"] = locale.to_s == "en" ? "en" : "es"
      uri.query = URI.encode_www_form(query)
    end
    uri.to_s
  rescue URI::InvalidURIError, ArgumentError
    nil
  end

  # Landing logo tiles size logos by area, not height: height ∝ 1/√aspect, so wide wordmarks
  # and compact marks carry the same visual weight. Returns a % of the tile height; falls back
  # to a 2:1 logo while the blob has not been analyzed yet.
  def marketing_logo_height(logo)
    meta = logo.blob.metadata
    width, height = meta["width"].to_f, meta["height"].to_f
    aspect = width.positive? && height.positive? ? width / height : 2.0
    [66, 82 / Math.sqrt(aspect)].min.round(1)
  end

  def marketing_store_link_data(platform)
    {
      locale_attrs: "href",
      locale_href_es: marketing_store_url(platform, locale: :es),
      locale_href_en: marketing_store_url(platform, locale: :en)
    }
  end
end
