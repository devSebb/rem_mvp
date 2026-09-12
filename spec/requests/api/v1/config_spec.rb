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
    expect(data["gift_card_limits"]).to eq("min_cents" => GiftCardLoad::MIN_LOAD_CENTS, "max_cents" => 20_000)
    # §8.2 limits mirror PlatformSetting's launch caps (§4.1)
    expect(data["limits"]).to eq(
      "min_load_cents" => 500,
      "max_load_cents" => 20_000,
      "max_daily_load_per_card_cents" => 40_000,
      "max_card_balance_cents" => 50_000,
      "max_loads_per_card_per_day" => 2,
      "max_daily_load_per_buyer_cents" => 60_000,
      "max_daily_loads_per_buyer" => 3,
      "max_30d_load_per_recipient_cents" => 100_000,
      "max_30d_load_per_buyer_cents" => 200_000,
      "buyer_refund_window_hours" => 72
    )
  end

  it "reflects a lowered cap in limits" do
    PlatformSetting.current.update!(max_load_cents: 10_000)

    get "/api/v1/config"

    data = JSON.parse(response.body)["data"]
    expect(data["limits"]["max_load_cents"]).to eq(10_000)
    expect(data["gift_card_limits"]["max_cents"]).to eq(10_000)
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
