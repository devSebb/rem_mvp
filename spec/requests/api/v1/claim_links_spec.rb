require "rails_helper"

RSpec.describe "Api::V1 ClaimLinks teaser", type: :request do
  let(:sender) { create(:user, first_name: "Ana") }
  let(:recipient) { create(:user, phone: "+593999123456") }
  let(:merchant) { create(:merchant) }
  let!(:gift_card) do
    create(:gift_card, sender:, recipient:, merchant:, amount: 2500, note: "Feliz cumple")
  end
  let(:token) { GiftCards::ClaimLink.issue!(gift_card) }

  describe "GET /api/v1/claim/:token" do
    it "returns the public teaser without authentication" do
      get "/api/v1/claim/#{token}"

      expect(response).to have_http_status(:ok)

      data = parsed_data
      expect(data["gift_card_id"]).to eq(gift_card.id)
      expect(data["status"]).to eq("active")
      expect(data["amount_cents"]).to eq(2500)
      expect(data["currency"]).to eq("USD")
      expect(data["merchant_name"]).to eq(merchant.store_name)
      expect(data["sender_first_name"]).to eq("Ana")
      expect(data["note"]).to eq("Feliz cumple")
      expect(data["recipient_masked_phone"]).to eq("+593•••3456")
      expect(data["recipient_registered"]).to be(true)
    end

    it "never exposes anything redeemable or personal beyond the teaser" do
      get "/api/v1/claim/#{token}"

      data = parsed_data
      expect(data.keys).not_to include(
        "code", "raw_code", "code_digest", "recipient_id", "sender_id",
        "recipient_phone", "recipient_email"
      )
      expect(response.body).not_to include(recipient.phone)
      expect(response.body).not_to include(recipient.email)
    end

    it "returns 404 for an unknown token" do
      get "/api/v1/claim/deadbeefdeadbeefdeadbeefdeadbeef"

      expect(response).to have_http_status(:not_found)
      expect(parsed_error["code"]).to eq("claim_link.not_found")
    end

    it "returns 404 once the link has expired" do
      token # issue before expiring
      gift_card.update_columns(link_token_expires_at: 1.minute.ago)

      get "/api/v1/claim/#{token}"

      expect(response).to have_http_status(:not_found)
      expect(parsed_error["code"]).to eq("claim_link.not_found")
    end
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
