require 'rails_helper'

RSpec.describe "Merchant::Settlements", type: :request do
  describe "GET /index" do
    it "returns http success" do
      get "/merchant/settlements/index"
      expect(response).to have_http_status(:success)
    end
  end

  describe "GET /show" do
    it "returns http success" do
      get "/merchant/settlements/show"
      expect(response).to have_http_status(:success)
    end
  end

end
