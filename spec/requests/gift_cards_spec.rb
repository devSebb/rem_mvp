require 'rails_helper'

RSpec.describe "GiftCards", type: :request do
  describe "GET /index" do
    it "returns http success" do
      get "/gift_cards"
      expect(response).to have_http_status(:found)
    end
  end

  describe "GET /show" do
    it "returns http success" do
      get "/gift_cards/1"
      expect(response).to have_http_status(:found)
    end
  end

  describe "GET /checkout" do
    it "returns http success" do
      post "/gift_cards/checkout", params: { amount_cents: 1, currency: "USD", recipient_email: "test@example.com" }
      expect(response).to have_http_status(:found)
    end
  end
end
