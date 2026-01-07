require 'rails_helper'

RSpec.describe "Merchant::Dashboards", type: :request do
  describe "GET /index" do
    it "returns http success" do
      get "/merchant"
      expect(response).to have_http_status(:found)
    end
  end
end
