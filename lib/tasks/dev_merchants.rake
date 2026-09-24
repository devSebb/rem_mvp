require "net/http"

module DevMerchantSync
  module_function

  def sync_merchant(attrs)
    name = attrs.fetch("store_name")
    merchant = Merchant.where("LOWER(store_name) = ?", name.downcase).order(:id).first ||
      Merchant.new(store_name: name, user: build_dev_merchant_user(name))

    partner = attrs["partner_redemption"] == true
    label = attrs["redemption_partner_label"].presence
    coverage = attrs["coverage_text"].presence
    merchant.assign_attributes(
      status: :active,
      address: merchant.address.presence || attrs["address"],
      categories: attrs["categories"] || [],
      partner_redemption: partner,
      redemption_partner_label: label == Merchant::DEFAULT_REDEMPTION_PARTNER_LABEL ? nil : label,
      # effective_coverage_text regenerates the partner sentence; only keep custom copy.
      coverage_text: (partner && coverage == "Para canjear esta tarjeta, paga en #{label}.") ? nil : coverage
    )
    was_new = merchant.new_record?
    merchant.save!

    if attrs["logo_url"].present?
      logo = fetch_with_redirects(URI(attrs["logo_url"]))
      content_type = logo["content-type"].to_s.split(";").first
      extension = Rack::Mime::MIME_TYPES.invert[content_type] || ".png"
      merchant.logo.attach(io: StringIO.new(logo.body), filename: "#{name.parameterize}#{extension}", content_type: content_type)
    end

    puts "  #{was_new ? 'created' : 'updated'} ##{merchant.id} #{name}#{' (logo)' if attrs['logo_url'].present?}"
    merchant
  end

  def build_dev_merchant_user(store_name)
    slug = store_name.parameterize
    password = SecureRandom.base58(16)
    User.new(
      email: "merchant+#{slug}@papayal.test",
      first_name: store_name,
      last_name: "Dev",
      phone: "+5939#{SecureRandom.random_number(10**8).to_s.rjust(8, '0')}",
      role: :merchant,
      password: password,
      password_confirmation: password
    )
  end

  def fetch_with_redirects(uri, limit = 5)
    raise "Too many redirects fetching #{uri}" if limit.zero?

    response = Net::HTTP.get_response(uri)
    case response
    when Net::HTTPSuccess then response
    when Net::HTTPRedirection then fetch_with_redirects(URI.join(uri.to_s, response["location"]), limit - 1)
    else raise "GET #{uri} failed: #{response.code}"
    end
  end
end

namespace :dev do
  # Mirrors the production public merchant catalog (names, logos, categories,
  # redemption copy) into the local database so the landing page and the
  # mobile app look like prod while developing. Read-only against prod: it
  # only calls the unauthenticated public merchants endpoint.
  #
  #   bin/rails dev:sync_prod_merchants
  #   KEEP_OTHERS=1 bin/rails dev:sync_prod_merchants   # don't suspend local-only merchants
  desc "Development only: copy prod's public merchant catalog and logos into the local DB"
  task sync_prod_merchants: :environment do
    abort "dev:sync_prod_merchants only runs in development." unless Rails.env.development?

    base = ENV.fetch("PROD_API_BASE", "https://api.papayal.app")
    response = DevMerchantSync.fetch_with_redirects(URI("#{base}/api/v1/public/merchants"))
    remote = JSON.parse(response.body).fetch("data")
    puts "Prod catalog: #{remote.size} merchants"

    synced_ids = remote.map { |attrs| DevMerchantSync.sync_merchant(attrs).id }

    others = Merchant.active.where.not(id: synced_ids)
    if ENV["KEEP_OTHERS"].present?
      puts "Kept #{others.count} local-only active merchants (KEEP_OTHERS set)."
    else
      others.each do |merchant|
        # Skip validations: old dev records may carry categories that no longer validate.
        merchant.update_columns(status: Merchant.statuses[:suspended], updated_at: Time.current)
        puts "  suspended local-only ##{merchant.id} #{merchant.store_name}"
      end
    end
  end
end
