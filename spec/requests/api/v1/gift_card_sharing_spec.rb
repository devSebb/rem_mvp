require "rails_helper"

# §5.9 / §8.2: share links and resends are per LOAD (sender only); the
# card-level routes stay as compat shims acting on the caller's latest load.
RSpec.describe "Api::V1 Me::GiftCards sharing", type: :request do
  let(:password) { "Password!23" }
  let(:json_headers) { { "Content-Type" => "application/json" } }
  let(:sender) { create(:user, password:, first_name: "Ana") }
  let(:recipient) { create(:user, password:, first_name: "Rita") }
  let(:merchant) { create(:merchant, store_name: "Medicity") }
  let!(:gift_card) { create(:gift_card, recipient:, merchant:, amount: 0) }
  let!(:load) { stripe_load!(gift_card, 2_500, sender: sender) }

  before { Rails.cache.clear }

  describe "POST /api/v1/me/gift_cards/:id/loads/:load_id/share_link" do
    it "returns the claim URL and the first-card WhatsApp message for the load's sender" do
      post "/api/v1/me/gift_cards/#{gift_card.id}/loads/#{load.id}/share_link",
           headers: auth_headers(access_token_for(sender))

      expect(response).to have_http_status(:ok)
      data = parsed_data
      expect(data["load_id"]).to eq(load.id)
      expect(data["claim_url"]).to include("/claim/")
      expect(data["message"]).to eq("¡Hola Rita! Te envié una tarjeta de regalo digital de Medicity por $25.00 con Papayal. Ábrela aquí: #{data['claim_url']}")

      token = data["claim_url"].split("/claim/").last
      expect(GiftCards::ClaimLink.find_by_token(token)).to eq(load)
    end

    it "uses the reload wording for a later load" do
      other = create(:user, password:, first_name: "Luis")
      reload = stripe_load!(gift_card, 1_000, sender: other)

      post "/api/v1/me/gift_cards/#{gift_card.id}/loads/#{reload.id}/share_link",
           headers: auth_headers(access_token_for(other))

      expect(response).to have_http_status(:ok)
      expect(parsed_data["message"]).to start_with("¡Hola Rita! Añadí $10.00 a tu tarjeta de Medicity en Papayal. Míralo aquí: ")
    end

    it "is forbidden for the recipient and for another buyer on the same card" do
      post "/api/v1/me/gift_cards/#{gift_card.id}/loads/#{load.id}/share_link",
           headers: auth_headers(access_token_for(recipient))
      expect(response).to have_http_status(:forbidden)

      other = create(:user, password:)
      stripe_load!(gift_card, 1_000, sender: other)
      post "/api/v1/me/gift_cards/#{gift_card.id}/loads/#{load.id}/share_link",
           headers: auth_headers(access_token_for(other))
      expect(response).to have_http_status(:forbidden)
    end

    it "rejects inactive cards" do
      gift_card.update!(status: :canceled)

      post "/api/v1/me/gift_cards/#{gift_card.id}/loads/#{load.id}/share_link",
           headers: auth_headers(access_token_for(sender))

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_error["code"]).to eq("gift_card.inactive")
    end

    it "requires authentication" do
      post "/api/v1/me/gift_cards/#{gift_card.id}/loads/#{load.id}/share_link", headers: json_headers

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "card-level compat shims" do
    it "share_link acts on the caller's latest load on the card" do
      later = stripe_load!(gift_card, 500, sender: sender)

      post "/api/v1/me/gift_cards/#{gift_card.id}/share_link", headers: auth_headers(access_token_for(sender))

      expect(response).to have_http_status(:ok)
      expect(parsed_data["load_id"]).to eq(later.id)
      expect(parsed_data["message"]).to include("$5.00")
    end

    it "resend acts on the caller's latest load and 422s for someone who never loaded the card" do
      expect {
        post "/api/v1/me/gift_cards/#{gift_card.id}/resend", headers: auth_headers(access_token_for(sender))
      }.to have_enqueued_job(LoadResendNotificationJob).with(load.id)
      expect(response).to have_http_status(:ok)

      other = create(:user, password:)
      stripe_load!(create(:gift_card, recipient: other, amount: 0), 500, sender: other) # visible elsewhere, not this card
      post "/api/v1/me/gift_cards/#{gift_card.id}/share_link", headers: auth_headers(access_token_for(other))
      expect(response).to have_http_status(:not_found) # not in their scope at all
    end
  end

  describe "POST /api/v1/me/gift_cards/:id/loads/:load_id/resend" do
    it "enqueues a resend for the load's sender" do
      expect {
        post "/api/v1/me/gift_cards/#{gift_card.id}/loads/#{load.id}/resend",
             headers: auth_headers(access_token_for(sender))
      }.to have_enqueued_job(LoadResendNotificationJob).with(load.id)

      expect(response).to have_http_status(:ok)
      expect(parsed_data["resent"]).to be(true)
      expect(parsed_data["load_id"]).to eq(load.id)
    end

    it "throttles back-to-back resends per card with a retry hint" do
      token = access_token_for(sender)

      post "/api/v1/me/gift_cards/#{gift_card.id}/loads/#{load.id}/resend", headers: auth_headers(token)
      expect(response).to have_http_status(:ok)

      post "/api/v1/me/gift_cards/#{gift_card.id}/loads/#{load.id}/resend", headers: auth_headers(token)

      expect(response).to have_http_status(:too_many_requests)
      expect(parsed_error["code"]).to eq("gift_card.resend_throttled")
      expect(parsed_error.dig("details", "retry_in_seconds")).to be_positive
    end

    it "enforces the daily per-card limit even after cooldowns" do
      token = access_token_for(sender)

      GiftCards::ResendDelivery::DAILY_LIMIT.times do
        post "/api/v1/me/gift_cards/#{gift_card.id}/loads/#{load.id}/resend", headers: auth_headers(token)
        expect(response).to have_http_status(:ok)
        Rails.cache.delete("gift_cards:resend:cooldown:#{gift_card.id}")
      end

      post "/api/v1/me/gift_cards/#{gift_card.id}/loads/#{load.id}/resend", headers: auth_headers(token)

      expect(response).to have_http_status(:too_many_requests)
      expect(parsed_error["code"]).to eq("gift_card.resend_throttled")
    end

    it "is forbidden for the recipient" do
      post "/api/v1/me/gift_cards/#{gift_card.id}/loads/#{load.id}/resend",
           headers: auth_headers(access_token_for(recipient))

      expect(response).to have_http_status(:forbidden)
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
