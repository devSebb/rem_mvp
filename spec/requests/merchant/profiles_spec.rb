require 'rails_helper'

RSpec.describe "Merchant::Profiles", type: :request do
  describe "GET /show" do
    it "returns http success" do
      get "/merchant/profile"
      expect(response).to have_http_status(:found)
    end
  end

  describe "GET /update" do
    it "returns http success" do
      patch "/merchant/profile", params: { user: { name: "Updated" } }
      expect(response).to have_http_status(:found)
    end
  end
end
