require 'rails_helper'

RSpec.describe "Merchant::Profiles", type: :request do
  describe "GET /show" do
    it "returns http success" do
      get "/merchant/profiles/show"
      expect(response).to have_http_status(:success)
    end
  end

  describe "GET /update" do
    it "returns http success" do
      get "/merchant/profiles/update"
      expect(response).to have_http_status(:success)
    end
  end

end
