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
        name: "New User",
        phone: "+15555550123",
        national_id: "ABC12345"
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

    it "returns 422 when national_id is missing" do
      expect do
        post "/api/v1/auth/signup",
             params: signup_params.except(:national_id).to_json,
             headers: json_headers
      end.not_to change(User, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_error["code"]).to eq("auth.signup_failed")
      expect(parsed_error.dig("details", "national_id")&.first).to match(/blank/i)
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

    it "returns 422 when name is missing" do
      expect do
        post "/api/v1/auth/signup",
             params: signup_params.except(:name).to_json,
             headers: json_headers
      end.not_to change(User, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_error["code"]).to eq("auth.signup_failed")
      expect(parsed_error.dig("details", "name")&.first).to match(/blank/i)
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

