# frozen_string_literal: true

require "rails_helper"

RSpec.describe "POST /api/v1/checkout/quote", type: :request do
  let(:password) { "Password!23" }
  let(:user) { create(:user, password: password) }
  let(:json_headers) { { "Content-Type" => "application/json" } }

  it "returns 401 without a token" do
    post "/api/v1/checkout/quote", params: { amount_cents: 5000 }.to_json, headers: json_headers

    expect(response).to have_http_status(:unauthorized)
  end

  it "returns a zero-fee quote with launch pricing" do
    post "/api/v1/checkout/quote",
         params: { amount_cents: 5000, currency: "USD" }.to_json,
         headers: auth_headers(access_token)

    expect(response).to have_http_status(:ok)
    expect(parsed_data).to eq(
      "subtotal_cents" => 5000,
      "fee_cents" => 0,
      "total_cents" => 5000,
      "currency" => "USD"
    )
  end

  it "reflects configured fees" do
    PlatformSetting.current.update!(buyer_fee_bps: 250, buyer_fee_fixed_cents: 30)

    post "/api/v1/checkout/quote",
         params: { amount_cents: 5000 }.to_json,
         headers: auth_headers(access_token)

    expect(response).to have_http_status(:ok)
    expect(parsed_data).to eq(
      "subtotal_cents" => 5000,
      "fee_cents" => 155,
      "total_cents" => 5155,
      "currency" => "USD"
    )
  end

  it "rejects invalid amounts" do
    post "/api/v1/checkout/quote",
         params: { amount_cents: 25_000 }.to_json,
         headers: auth_headers(access_token)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(parsed_error["code"]).to eq("invalid_amount")
  end

  it "rejects non-USD currencies" do
    post "/api/v1/checkout/quote",
         params: { amount_cents: 5000, currency: "EUR" }.to_json,
         headers: auth_headers(access_token)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(parsed_error["code"]).to eq("invalid_currency")
  end

  it "returns 503 when purchases are disabled" do
    PlatformSetting.current.update!(purchases_enabled: false)

    post "/api/v1/checkout/quote",
         params: { amount_cents: 5000 }.to_json,
         headers: auth_headers(access_token)

    expect(response).to have_http_status(:service_unavailable)
    expect(parsed_error["code"]).to eq("purchases_disabled")
  end

  def access_token
    @access_token ||= begin
      post "/api/v1/auth/login",
           params: { email: user.email, password: password }.to_json,
           headers: json_headers

      JSON.parse(response.body).dig("data", "access_token")
    end
  end

  def parsed_body
    JSON.parse(response.body)
  end

  def parsed_data
    parsed_body["data"] || {}
  end

  def parsed_error
    parsed_body["error"] || {}
  end

  def auth_headers(token)
    json_headers.merge("Authorization" => "Bearer #{token}")
  end
end
