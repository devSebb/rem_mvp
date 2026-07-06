require "rails_helper"

RSpec.describe "Api::V1 GiftCards by_payment_intent", type: :request do
  let(:password) { "Password!23" }
  let(:json_headers) { { "Content-Type" => "application/json" } }
  let(:sender) { create(:user, password:) }
  let(:recipient) { create(:user, password:) }
  let(:merchant) { create(:merchant) }
  let(:payment_intent_id) { "pi_test_abc123" }
  let!(:gift_card) do
    create(
      :gift_card,
      sender:,
      recipient:,
      merchant:,
      payment_intent_id:,
      note: "Feliz cumpleaños"
    )
  end

  describe "GET /api/v1/gift_cards/by_payment_intent/:payment_intent_id" do
    it "returns the gift card in the mobile serializer shape for the sender" do
      get "/api/v1/gift_cards/by_payment_intent/#{payment_intent_id}",
          headers: auth_headers(access_token_for(sender))

      expect(response).to have_http_status(:ok)
      expect(parsed_body["request_id"]).to be_present

      data = parsed_data
      expect(data["id"]).to eq(gift_card.id)
      expect(data["amount_cents"]).to eq(gift_card.amount)
      expect(data["remaining_balance_cents"]).to eq(gift_card.reload.remaining_balance)
      expect(data["currency"]).to eq(gift_card.currency)
      expect(data["status"]).to eq("active")
      expect(data["created_at"]).to eq(gift_card.created_at.iso8601)
      expect(data["sender_id"]).to eq(sender.id)
      expect(data["recipient_id"]).to eq(recipient.id)
      expect(data["merchant_id"]).to eq(merchant.id)
      expect(data["merchant"]).to include("id" => merchant.id, "store_name" => merchant.store_name)
      expect(data["store_name"]).to eq(merchant.store_name)
      expect(data["merchant_name"]).to eq(merchant.store_name)
      expect(data["merchant_store_name"]).to eq(merchant.store_name)
      expect(data["note"]).to eq("Feliz cumpleaños")
      expect(data["sender"]).to include(
        "id" => sender.id,
        "name" => sender.first_name,
        "last_name" => sender.last_name
      )
      expect(data).to have_key("merchant_logo_url")
      expect(data).to have_key("held_until")
    end

    it "returns the gift card for the recipient" do
      get "/api/v1/gift_cards/by_payment_intent/#{payment_intent_id}",
          headers: auth_headers(access_token_for(recipient))

      expect(response).to have_http_status(:ok)
      expect(parsed_data["id"]).to eq(gift_card.id)
    end

    it "returns 404 for a user who is neither sender nor recipient (no existence leak)" do
      stranger = create(:user, password:)

      get "/api/v1/gift_cards/by_payment_intent/#{payment_intent_id}",
          headers: auth_headers(access_token_for(stranger))

      expect(response).to have_http_status(:not_found)
      expect(parsed_error["code"]).to eq("not_found")
    end

    it "returns 401 without an access token" do
      get "/api/v1/gift_cards/by_payment_intent/#{payment_intent_id}"

      expect(response).to have_http_status(:unauthorized)
      expect(parsed_error["code"]).to eq("auth.missing_token")
    end

    it "returns 404 while the webhook has not created the card yet (polling contract)" do
      get "/api/v1/gift_cards/by_payment_intent/pi_not_created_yet",
          headers: auth_headers(access_token_for(sender))

      expect(response).to have_http_status(:not_found)
      expect(parsed_error["code"]).to eq("not_found")
    end
  end

  def access_token_for(login_user)
    post "/api/v1/auth/login",
         params: { email: login_user.email, password: password }.to_json,
         headers: json_headers

    expect(response).to have_http_status(:ok)
    parsed_data["access_token"]
  end

  def auth_headers(token)
    json_headers.merge("Authorization" => "Bearer #{token}")
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
end
