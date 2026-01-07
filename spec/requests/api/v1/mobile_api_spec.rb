require "rails_helper"

RSpec.describe "Mobile API", type: :request do
  let(:password) { "Password!23" }
  let(:user) { create(:user, password:) }
  let(:json_headers) { { "Content-Type" => "application/json" } }

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

