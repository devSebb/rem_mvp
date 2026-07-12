# frozen_string_literal: true

require "rails_helper"

RSpec.describe "GET /api/v1/config", type: :request do
  it "is public and returns defaults" do
    get "/api/v1/config"

    expect(response).to have_http_status(:ok)
    data = JSON.parse(response.body)["data"]
    expect(data["purchases_enabled"]).to be(true)
    expect(data["min_supported_version"]).to eq("ios" => nil, "android" => nil)
    expect(data["fees"]).to eq("buyer_fee_bps" => 0, "buyer_fee_fixed_cents" => 0)
    expect(data["gift_card_limits"]).to eq("min_cents" => 100, "max_cents" => GiftCard::MAX_AMOUNT_CENTS)
  end

  it "reflects admin-configured settings" do
    PlatformSetting.current.update!(
      buyer_fee_bps: 100,
      purchases_enabled: false,
      min_ios_version: "1.2.0"
    )

    get "/api/v1/config"

    data = JSON.parse(response.body)["data"]
    expect(data["purchases_enabled"]).to be(false)
    expect(data["fees"]["buyer_fee_bps"]).to eq(100)
    expect(data["min_supported_version"]["ios"]).to eq("1.2.0")
  end
end
