require "rails_helper"

RSpec.describe "AppLinks web fallback pages", type: :request do
  let(:sender) { create(:user, first_name: "Ana") }
  let(:recipient) { create(:user) }
  let(:merchant) { create(:merchant) }
  let!(:gift_card) { create(:gift_card, sender:, recipient:, merchant:, amount: 2500) }

  describe "GET /claim/:token" do
    it "renders the gift teaser without authentication" do
      token = GiftCards::ClaimLink.issue!(gift_card)

      get "/claim/#{token}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Ana")
      expect(response.body).to include("USD 25.00")
      expect(response.body).to include(merchant.store_name)
      expect(response.body).to include("papayal://claim/#{token}")
    end

    it "never renders anything redeemable" do
      token = GiftCards::ClaimLink.issue!(gift_card)

      get "/claim/#{token}"

      expect(response.body).not_to include(gift_card.raw_code)
      expect(response.body).not_to include(recipient.email)
    end

    it "renders the friendly expired state for an unknown token" do
      get "/claim/deadbeefdeadbeefdeadbeefdeadbeef"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Este enlace ya no está activo")
    end

    it "renders the expired state for inactive cards" do
      token = GiftCards::ClaimLink.issue!(gift_card)
      gift_card.update!(status: :redeemed, remaining_balance: 0)

      get "/claim/#{token}"

      expect(response.body).to include("Este enlace ya no está activo")
    end
  end

  describe "GET /reset" do
    it "renders the reset instructions with the app-scheme link" do
      get "/reset", params: { token: "abc123" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Restablece tu contraseña en la app")
      expect(response.body).to include("papayal://reset?token=abc123")
    end

    it "renders without a token" do
      get "/reset"

      expect(response).to have_http_status(:ok)
    end
  end
end
