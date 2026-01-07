require 'rails_helper'

RSpec.describe "Merchant::Redemptions", type: :request do
  describe "GET /new" do
    it "returns http success" do
      get "/merchant/redemptions/new"
      expect(response).to have_http_status(:found)
    end
  end

  describe "GET /create" do
    it "returns http success" do
      post "/merchant/redemptions", params: { token: "TEST", amount: "1.00" }
      expect(response).to have_http_status(:found)
    end
  end

  describe "GET /confirm" do
    it "returns http success" do
      get "/merchant/redemptions/confirm"
      expect(response).to have_http_status(:found)
    end
  end
end
