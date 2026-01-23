require "rails_helper"

RSpec.describe "Mobile API", type: :request do
  let(:password) { "Password!23" }
  let(:user) { create(:user, password:) }
  let(:json_headers) { { "Content-Type" => "application/json" } }

  describe "POST /api/v1/auth/signup" do
    let(:signup_params) do
      {
        email: "new_user@example.com",
        password: "Password!23",
        password_confirmation: "Password!23",
        first_name: "New",
        last_name: "User",
        phone: "+15555550123"
      }
    end

    it "returns tokens and creates a User" do
      expect do
        post "/api/v1/auth/signup",
             params: signup_params.to_json,
             headers: json_headers
      end.to change(User, :count).by(1)
         .and change(UserSession, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(parsed_data["access_token"]).to be_present
      expect(parsed_data["refresh_token"]).to be_present
      expect(parsed_data["expires_in"]).to be > 0
      expect(parsed_body["request_id"]).to be_present
    end

    it "returns 422 for duplicate email" do
      existing_user = create(:user)

      expect do
        post "/api/v1/auth/signup",
             params: signup_params.merge(email: existing_user.email).to_json,
             headers: json_headers
      end.not_to change(User, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_error["code"]).to eq("auth.signup_failed")
      expect(parsed_error.dig("details", "email")&.first).to match(/taken/)
    end

    it "returns 422 when phone is missing" do
      expect do
        post "/api/v1/auth/signup",
             params: signup_params.except(:phone).to_json,
             headers: json_headers
      end.not_to change(User, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_error["code"]).to eq("auth.signup_failed")
      expect(parsed_error.dig("details", "phone")&.first).to match(/blank/i)
    end

    it "returns 422 when first_name is missing" do
      expect do
        post "/api/v1/auth/signup",
             params: signup_params.except(:first_name).to_json,
             headers: json_headers
      end.not_to change(User, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_error["code"]).to eq("auth.signup_failed")
      expect(parsed_error.dig("details", "first_name")&.first).to match(/blank/i)
    end

    it "returns 422 when last_name is missing" do
      expect do
        post "/api/v1/auth/signup",
             params: signup_params.except(:last_name).to_json,
             headers: json_headers
      end.not_to change(User, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_error["code"]).to eq("auth.signup_failed")
      expect(parsed_error.dig("details", "last_name")&.first).to match(/blank/i)
    end

    it "returns 422 for weak password" do
      weak_params = signup_params.merge(email: "weak@example.com", password: "short", password_confirmation: "short")

      expect do
        post "/api/v1/auth/signup",
             params: weak_params.to_json,
             headers: json_headers
      end.not_to change(User, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_error["code"]).to eq("auth.signup_failed")
      expect(parsed_error.dig("details", "password")&.join).to match(/too short/i)
    end
  end

  describe "POST /api/v1/auth/login" do
    it "returns access and refresh tokens" do
      expect do
        post "/api/v1/auth/login",
             params: { email: user.email, password: password }.to_json,
             headers: json_headers
      end.to change(UserSession, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(parsed_data["access_token"]).to be_present
      expect(parsed_data["refresh_token"]).to be_present
      expect(parsed_data["expires_in"]).to be > 0
      expect(parsed_body["request_id"]).to be_present
    end
  end

  describe "POST /api/v1/auth/refresh" do
    it "rotates the refresh token and invalidates the old one" do
      tokens = login_and_get_tokens

      post "/api/v1/auth/refresh",
           params: { refresh_token: tokens[:refresh_token] }.to_json,
           headers: json_headers

      expect(response).to have_http_status(:ok)
      new_refresh = parsed_data["refresh_token"]
      expect(new_refresh).to be_present
      expect(new_refresh).not_to eq(tokens[:refresh_token])

      post "/api/v1/auth/refresh",
           params: { refresh_token: tokens[:refresh_token] }.to_json,
           headers: json_headers

      expect(response).to have_http_status(:unauthorized)
      expect(parsed_error["code"]).to eq("auth.refresh_revoked")
    end
  end

  describe "GET /api/v1/me" do
    it "returns current user with avatar urls" do
      get "/api/v1/me", headers: auth_headers(login_and_get_tokens[:access_token])

      expect(response).to have_http_status(:ok)
      expect(parsed_data["id"]).to eq(user.id)
      expect(parsed_data["first_name"]).to eq(user.first_name)
      expect(parsed_data["last_name"]).to eq(user.last_name)
      expect(parsed_data["name"]).to eq(user.full_name)
      expect(parsed_data["address"]).to be_nil
      expect(parsed_data["country_of_residence"]).to be_nil
      expect(parsed_data["date_of_birth"]).to be_nil
      expect(parsed_data).not_to have_key("national_id")
      expect(parsed_data["avatar_url"]).to be_nil
      expect(parsed_data["avatar_thumb_url"]).to be_nil
    end
  end

  describe "PATCH /api/v1/me" do
    let(:update_params) do
      {
        address: "Calle Falsa 123",
        country_of_residence: "PE",
        date_of_birth: "1990-01-01"
      }
    end

    it "updates profile fields and returns the profile" do
      tokens = login_and_get_tokens

      patch "/api/v1/me",
            params: update_params.to_json,
            headers: auth_headers(tokens[:access_token])

      expect(response).to have_http_status(:ok)
      expect(parsed_data["address"]).to eq("Calle Falsa 123")
      expect(parsed_data["country_of_residence"]).to eq("PE")
      expect(parsed_data["date_of_birth"]).to eq("1990-01-01")
      expect(parsed_data).not_to have_key("national_id")
      user.reload
      expect(user.address).to eq("Calle Falsa 123")
      expect(user.country_of_residence).to eq("PE")
      expect(user.date_of_birth.to_s).to eq("1990-01-01")
    end
  end

  describe "POST /api/v1/checkout/validate_kyc" do
    it "returns missing fields when profile is incomplete" do
      tokens = login_and_get_tokens

      post "/api/v1/checkout/validate_kyc",
           headers: auth_headers(tokens[:access_token])

      expect(response).to have_http_status(:ok)
      expect(parsed_data["ok"]).to be(false)
      expect(parsed_data["missing"]).to match_array(%w[address country_of_residence date_of_birth])
    end

    it "returns ok when profile has all KYC fields" do
      tokens = login_and_get_tokens
      user.update!(address: "123 Main St", country_of_residence: "PE", date_of_birth: Date.new(1990, 1, 1))

      post "/api/v1/checkout/validate_kyc",
           headers: auth_headers(tokens[:access_token])

      expect(response).to have_http_status(:ok)
      expect(parsed_data["ok"]).to be(true)
      expect(parsed_data["missing"]).to eq([])
    end
  end

  describe "POST /api/v1/me/avatar" do
    let(:avatar_file) do
      Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/avatar.png"), "image/png")
    end

    it "uploads and returns avatar urls" do
      post "/api/v1/me/avatar",
           params: { avatar: avatar_file },
           headers: { "Authorization" => "Bearer #{login_and_get_tokens[:access_token]}" }

      expect(response).to have_http_status(:ok)
      expect(parsed_data["avatar_url"]).to be_present
      expect(parsed_data).to have_key("avatar_thumb_url")
    end
  end

  describe "POST /api/v1/auth/logout" do
    it "revokes the supplied refresh token" do
      tokens = login_and_get_tokens

      post "/api/v1/auth/logout",
           params: { refresh_token: tokens[:refresh_token] }.to_json,
           headers: json_headers

      expect(response).to have_http_status(:ok)

      post "/api/v1/auth/refresh",
           params: { refresh_token: tokens[:refresh_token] }.to_json,
           headers: json_headers

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /api/v1/me/gift_cards" do
    it "returns only gift cards in the policy scope" do
      owned_card = create(:gift_card, recipient: user, sender: user)
      _other_card = create(:gift_card) # not associated to user

      get "/api/v1/me/gift_cards", headers: auth_headers(login_and_get_tokens[:access_token])

      expect(response).to have_http_status(:ok)
      ids = parsed_data.map { |gc| gc["id"] }
      expect(ids).to include(owned_card.id)
      expect(ids).not_to include(_other_card.id)
    end

    it "returns ordered gift cards with sender/recipient and merchant info" do
      merchant = create(:merchant)
      older = create(:gift_card, recipient: user, sender: user, merchant: merchant)
      newer = create(:gift_card, recipient: user, sender: user, merchant: merchant)
      older.update_columns(created_at: 3.days.ago, updated_at: 2.days.ago)
      newer.update_columns(updated_at: 1.hour.ago)

      get "/api/v1/me/gift_cards", headers: auth_headers(login_and_get_tokens[:access_token])

      expect(response).to have_http_status(:ok)
      expect(parsed_data.first["id"]).to eq(newer.id)
      expect(parsed_data.second["id"]).to eq(older.id)

      card = parsed_data.first
      expect(card["sender_id"]).to eq(newer.sender_id)
      expect(card["recipient_id"]).to eq(newer.recipient_id)
      expect(card["created_at"]).to be_present
      expect(card["updated_at"]).to be_present
      expect(card["merchant"]).to include("id" => merchant.id, "store_name" => merchant.store_name)
      expect(card["store_name"]).to eq(merchant.store_name)
      expect(card["merchant_name"]).to eq(merchant.store_name)
      expect(card["merchant_store_name"]).to eq(merchant.store_name)
      expect(card["merchant_logo_url"]).to be_nil
    end

    it "updates last_owner_activity_at for all accessed gift cards" do
      card1 = create(:gift_card, recipient: user, sender: user)
      card2 = create(:gift_card, recipient: user, sender: user)
      expect(card1.last_owner_activity_at).to be_nil
      expect(card2.last_owner_activity_at).to be_nil

      get "/api/v1/me/gift_cards", headers: auth_headers(login_and_get_tokens[:access_token])

      expect(response).to have_http_status(:ok)
      card1.reload
      card2.reload
      expect(card1.last_owner_activity_at).to be_present
      expect(card2.last_owner_activity_at).to be_present
      expect(card1.last_owner_activity_at).to be_within(5.seconds).of(Time.current)
      expect(card2.last_owner_activity_at).to be_within(5.seconds).of(Time.current)
    end

    it "does not include expires_at in response (gift cards never expire)" do
      create(:gift_card, recipient: user, sender: user)

      get "/api/v1/me/gift_cards", headers: auth_headers(login_and_get_tokens[:access_token])

      expect(response).to have_http_status(:ok)
      parsed_data.each do |card|
        expect(card).not_to have_key("expires_at")
      end
    end
  end

  describe "GET /api/v1/me/gift_cards/:id" do
    it "returns gift card with sender/recipient and merchant info" do
      merchant = create(:merchant)
      gift_card = create(:gift_card, recipient: user, sender: user, merchant: merchant)

      get "/api/v1/me/gift_cards/#{gift_card.id}", headers: auth_headers(login_and_get_tokens[:access_token])

      expect(response).to have_http_status(:ok)
      card = parsed_data
      expect(card["id"]).to eq(gift_card.id)
      expect(card["sender_id"]).to eq(gift_card.sender_id)
      expect(card["recipient_id"]).to eq(gift_card.recipient_id)
      expect(card["created_at"]).to be_present
      expect(card["updated_at"]).to be_present
      expect(card["merchant"]).to include("id" => merchant.id, "store_name" => merchant.store_name)
      expect(card["store_name"]).to eq(merchant.store_name)
      expect(card["merchant_name"]).to eq(merchant.store_name)
    end

    it "updates last_owner_activity_at when viewing gift card" do
      gift_card = create(:gift_card, recipient: user, sender: user)
      expect(gift_card.last_owner_activity_at).to be_nil

      get "/api/v1/me/gift_cards/#{gift_card.id}", headers: auth_headers(login_and_get_tokens[:access_token])

      expect(response).to have_http_status(:ok)
      gift_card.reload
      expect(gift_card.last_owner_activity_at).to be_present
      expect(gift_card.last_owner_activity_at).to be_within(5.seconds).of(Time.current)
    end

    it "does not include expires_at in response (gift cards never expire)" do
      gift_card = create(:gift_card, recipient: user, sender: user)

      get "/api/v1/me/gift_cards/#{gift_card.id}", headers: auth_headers(login_and_get_tokens[:access_token])

      expect(response).to have_http_status(:ok)
      expect(parsed_data).not_to have_key("expires_at")
    end
  end

  describe "GET /api/v1/merchants" do
    it "returns list of active merchants with categories" do
      merchant = create(:merchant, categories: ["Café", "Panadería"])

      get "/api/v1/merchants", headers: auth_headers(login_and_get_tokens[:access_token])

      expect(response).to have_http_status(:ok)
      expect(parsed_data).to be_an(Array)
      merchant_data = parsed_data.find { |m| m["id"] == merchant.id }
      expect(merchant_data).to be_present
      expect(merchant_data["store_name"]).to eq(merchant.store_name)
      expect(merchant_data["categories"]).to eq(["Café", "Panadería"])
    end
  end

  describe "GET /api/v1/merchants/:id" do
    it "returns merchant details with categories" do
      merchant = create(:merchant, categories: ["Café", "Panadería", "Desayunos"])

      get "/api/v1/merchants/#{merchant.id}", headers: auth_headers(login_and_get_tokens[:access_token])

      expect(response).to have_http_status(:ok)
      expect(parsed_data["id"]).to eq(merchant.id)
      expect(parsed_data["store_name"]).to eq(merchant.store_name)
      expect(parsed_data["name"]).to eq(merchant.name)
      expect(parsed_data["status"]).to eq("active")
      expect(parsed_data["categories"]).to eq(["Café", "Panadería", "Desayunos"])
      expect(parsed_data["address"]).to eq(merchant.address)
      expect(parsed_data["contact_email"]).to eq(merchant.contact_email)
      expect(parsed_data["logo_url"]).to be_nil
      expect(parsed_data["created_at"]).to be_present
      expect(parsed_data["updated_at"]).to be_present
      expect(parsed_body["request_id"]).to be_present
    end

    it "returns 404 for non-existent merchant" do
      get "/api/v1/merchants/99999", headers: auth_headers(login_and_get_tokens[:access_token])

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for suspended merchant if not admin (reduces enumeration)" do
      merchant = create(:merchant, status: :suspended)

      get "/api/v1/merchants/#{merchant.id}", headers: auth_headers(login_and_get_tokens[:access_token])

      expect(response).to have_http_status(:not_found)
    end

    it "allows admin to view suspended merchant" do
      admin = create(:user, role: :admin, password: password)
      merchant = create(:merchant, status: :suspended)

      admin_tokens = login_and_get_tokens(login_user: admin, login_password: password)

      get "/api/v1/merchants/#{merchant.id}", headers: auth_headers(admin_tokens[:access_token])

      expect(response).to have_http_status(:ok)
      expect(parsed_data["id"]).to eq(merchant.id)
      expect(parsed_data["status"]).to eq("suspended")
    end
  end

  describe "POST /api/v1/me/gift_cards/:id/redemption_token" do
    it "respects GiftCardPolicy#view_code? authorization" do
      # User is sender, not recipient -> should be forbidden
      gift_card = create(:gift_card, sender: user, recipient: create(:user))

      post "/api/v1/me/gift_cards/#{gift_card.id}/redemption_token",
           headers: auth_headers(login_and_get_tokens[:access_token])

      expect(response).to have_http_status(:forbidden)
      expect(parsed_error["code"]).to eq("forbidden")
    end

    it "issues a redemption token for a recipient" do
      gift_card = create(:gift_card, recipient: user, sender: create(:user), status: :active)

      post "/api/v1/me/gift_cards/#{gift_card.id}/redemption_token",
           headers: auth_headers(login_and_get_tokens[:access_token])

      expect(response).to have_http_status(:ok)
      expect(parsed_data["token"]).to be_present
      expect(parsed_data["expires_at"]).to be_present
    end
  end

  def login_and_get_tokens(login_user: user, login_password: password)
    post "/api/v1/auth/login",
         params: { email: login_user.email, password: login_password }.to_json,
         headers: json_headers

    expect(response).to have_http_status(:ok)

    {
      access_token: parsed_data["access_token"],
      refresh_token: parsed_data["refresh_token"]
    }
  end

  def parsed_body
    JSON.parse(response.body)
  end

  def parsed_data
    parsed_body["data"]
  end

  def parsed_error
    parsed_body["error"] || {}
  end

  def auth_headers(token)
    json_headers.merge("Authorization" => "Bearer #{token}")
  end
end

