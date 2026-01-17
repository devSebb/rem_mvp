require "rails_helper"

RSpec.describe "Api::V1::GiftCards", type: :request do
  let(:merchant_secret) { "sec_test_key_123" }
  let(:merchant) { create_merchant(secret: merchant_secret) }
  let(:gift_card) { create_gift_card(merchant:) }
  let(:raw_token) { issue_token_for(gift_card) }

  describe "POST /api/v1/gift_cards/validate" do
    let(:endpoint) { "/api/v1/gift_cards/validate" }

    it "returns remaining balance when the gift card can cover the amount" do
      post endpoint,
           params: { token: raw_token, amount_cents: 2_000 }.to_json,
           headers: auth_headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["valid"]).to be(true)
      expect(body["gift_card_id"]).to eq(gift_card.id)
      expect(body["remaining_balance_cents"]).to eq(gift_card.remaining_balance)
      expect(body["currency"]).to eq(gift_card.currency)
    end

    it "returns insufficient_funds when the amount exceeds the balance" do
      post endpoint,
           params: { token: raw_token, amount_cents: 20_000 }.to_json,
           headers: auth_headers

      expect(response).to have_http_status(:unprocessable_entity)
      body = JSON.parse(response.body)
      expect(body["valid"]).to be(false)
      expect(body["error"]).to eq("insufficient_funds")
      expect(body["gift_card_id"]).to eq(gift_card.id)
      expect(body["remaining_balance_cents"]).to eq(gift_card.remaining_balance)
    end

    it "returns inactive_gift_card when the gift card is not active" do
      gift_card.update!(status: :canceled)

      post endpoint,
           params: { token: raw_token, amount_cents: 2_000 }.to_json,
           headers: auth_headers

      expect(response).to have_http_status(:unprocessable_entity)
      body = JSON.parse(response.body)
      expect(body["valid"]).to be(false)
      expect(body["error"]).to eq("inactive_gift_card")
    end

    it "rejects requests without authentication" do
      post endpoint,
           params: { token: raw_token, amount_cents: 2_000 }.to_json,
           headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:unauthorized)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("Missing Authorization header")
    end

    it "rejects requests made with an invalid secret" do
      post endpoint,
           params: { token: raw_token, amount_cents: 2_000 }.to_json,
           headers: auth_headers("wrong-secret")

      expect(response).to have_http_status(:unauthorized)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("Unauthorized")
    end

    it "allows validation even when the gift card was issued by another merchant" do
      other_secret = "other-secret"
      create_merchant(secret: other_secret)

      post endpoint,
           params: { token: raw_token, amount_cents: 2_000 }.to_json,
           headers: auth_headers(other_secret)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["valid"]).to eq(true)
    end
  end

  describe "GET /api/v1/gift_cards/:token" do
    it "returns the gift card balance and status" do
      get "/api/v1/gift_cards/#{raw_token}", headers: auth_headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["gift_card_id"]).to eq(gift_card.id)
      expect(body["balance_cents"]).to eq(gift_card.remaining_balance)
      expect(body["currency"]).to eq(gift_card.currency)
      expect(body["status"]).to eq(gift_card.status)
    end

    it "returns 404 when the token is unknown" do
      get "/api/v1/gift_cards/UNKNOWN", headers: auth_headers

      expect(response).to have_http_status(:not_found)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("Not Found")
    end

    it "does not update last_owner_activity_at (merchant endpoint, not owner activity)" do
      original_activity_at = gift_card.last_owner_activity_at

      get "/api/v1/gift_cards/#{raw_token}", headers: auth_headers

      expect(response).to have_http_status(:ok)
      gift_card.reload
      expect(gift_card.last_owner_activity_at).to eq(original_activity_at)
    end
  end

  def auth_headers(secret = merchant_secret)
    merchant
    {
      "Authorization" => "Bearer #{secret}",
      "Content-Type" => "application/json"
    }
  end

  def create_merchant(secret:)
    Merchant.create!(
      user: create_user(role: :merchant),
      store_name: "Demo Store",
      name: "Demo Store",
      address: "123 Main Street",
      contact_email: "merchant-#{SecureRandom.hex(4)}@example.com",
      bank_account_iban: "US12345#{SecureRandom.hex(2)}",
      status: :active,
      public_key: "pub_#{SecureRandom.hex(8)}",
      secret_key_digest: Merchant.digest_secret(secret)
    )
  end

  def create_user(role:)
    User.create!(
      email: "#{role}-#{SecureRandom.hex(6)}@example.com",
      password: "Password!23",
      name: "#{role.to_s.capitalize} #{SecureRandom.hex(4)}",
      first_name: role.to_s.capitalize,
      last_name: SecureRandom.hex(4),
      phone: "+#{SecureRandom.rand(1..999)}#{SecureRandom.rand(1000000..9999999)}", # Random country code + number
      role: role,
      national_id: "TEST#{SecureRandom.hex(4)}".upcase
    )
  end

  def create_gift_card(merchant:)
    sender = create_user(role: :user)
    GiftCard.create!(
      sender:,
      recipient: sender,
      merchant:,
      amount: 10_000,
      remaining_balance: 10_000,
      currency: "USD",
      code_digest: BCrypt::Password.create(SecureRandom.hex(8)),
      status: :active,
      expires_at: nil # Gift cards never expire
    )
  end

  def issue_token_for(gift_card)
    raw_token = SecureRandom.base58(10).upcase
    gift_card.redemption_tokens.create!(
      token_digest: RedemptionToken.digest(raw_token),
      expires_at: 5.minutes.from_now
    )
    raw_token
  end
end
