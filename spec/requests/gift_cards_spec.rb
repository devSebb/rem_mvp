require 'rails_helper'

RSpec.describe "GiftCards", type: :request do
  describe "GET /index" do
    it "returns http success" do
      get "/gift_cards/index"
      expect(response).to have_http_status(:success)
    end
  end

  describe "GET /show" do
    it "returns http success" do
      get "/gift_cards/show"
      expect(response).to have_http_status(:success)
    end
  end

  describe "GET /checkout" do
    it "returns http success" do
      get "/gift_cards/checkout"
      expect(response).to have_http_status(:success)
    end
  end

end
