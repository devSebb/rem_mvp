require 'rails_helper'

RSpec.describe "Merchant::Settlements", type: :request do
  describe "GET /index" do
    it "returns http success" do
      get "/merchant/settlements"
      expect(response).to have_http_status(:found)
    end
  end

  describe "GET /show" do
    it "returns http success" do
      get "/merchant/settlements/1"
      expect(response).to have_http_status(:found)
    end
  end
end
