require "rails_helper"

RSpec.describe "Api::V1 Me::GiftCards sharing", type: :request do
  let(:password) { "Password!23" }
  let(:json_headers) { { "Content-Type" => "application/json" } }
  let(:sender) { create(:user, password:) }
  let(:recipient) { create(:user, password:) }
  let(:merchant) { create(:merchant) }
  let!(:gift_card) { create(:gift_card, sender:, recipient:, merchant:, amount: 2500) }

  before { Rails.cache.clear }

  describe "POST /api/v1/me/gift_cards/:id/share_link" do
    it "returns a claim URL and prewritten message for the sender" do
      post "/api/v1/me/gift_cards/#{gift_card.id}/share_link",
           headers: auth_headers(access_token_for(sender))

      expect(response).to have_http_status(:ok)

      data = parsed_data
      expect(data["claim_url"]).to include("/claim/")
      expect(data["message"]).to include(data["claim_url"])
      expect(data["message"]).to include("USD 25.00")
      expect(data["message"]).to include(merchant.store_name)

      token = data["claim_url"].split("/claim/").last
      expect(GiftCards::ClaimLink.find_by_token(token)).to eq(gift_card)
    end

    it "is forbidden for the recipient" do
      post "/api/v1/me/gift_cards/#{gift_card.id}/share_link",
           headers: auth_headers(access_token_for(recipient))

      expect(response).to have_http_status(:forbidden)
    end

    it "rejects inactive cards" do
      gift_card.update!(status: :redeemed, remaining_balance: 0)

      post "/api/v1/me/gift_cards/#{gift_card.id}/share_link",
           headers: auth_headers(access_token_for(sender))

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_error["code"]).to eq("gift_card.inactive")
    end

    it "requires authentication" do
      post "/api/v1/me/gift_cards/#{gift_card.id}/share_link", headers: json_headers

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "POST /api/v1/me/gift_cards/:id/resend" do
    it "enqueues a resend for the sender" do
      expect {
        post "/api/v1/me/gift_cards/#{gift_card.id}/resend",
             headers: auth_headers(access_token_for(sender))
      }.to have_enqueued_job(ResendNotificationJob).with(gift_card.id)

      expect(response).to have_http_status(:ok)
      expect(parsed_data["resent"]).to be(true)
    end

    it "throttles back-to-back resends with a retry hint" do
      token = access_token_for(sender)

      post "/api/v1/me/gift_cards/#{gift_card.id}/resend", headers: auth_headers(token)
      expect(response).to have_http_status(:ok)

      post "/api/v1/me/gift_cards/#{gift_card.id}/resend", headers: auth_headers(token)

      expect(response).to have_http_status(:too_many_requests)
      expect(parsed_error["code"]).to eq("gift_card.resend_throttled")
      expect(parsed_error.dig("details", "retry_in_seconds")).to be_positive
    end

    it "enforces the daily per-card limit even after cooldowns" do
      token = access_token_for(sender)

      GiftCards::ResendDelivery::DAILY_LIMIT.times do
        post "/api/v1/me/gift_cards/#{gift_card.id}/resend", headers: auth_headers(token)
        expect(response).to have_http_status(:ok)
        Rails.cache.delete("gift_cards:resend:cooldown:#{gift_card.id}")
      end

      post "/api/v1/me/gift_cards/#{gift_card.id}/resend", headers: auth_headers(token)

      expect(response).to have_http_status(:too_many_requests)
      expect(parsed_error["code"]).to eq("gift_card.resend_throttled")
    end

    it "is forbidden for the recipient" do
      post "/api/v1/me/gift_cards/#{gift_card.id}/resend",
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
