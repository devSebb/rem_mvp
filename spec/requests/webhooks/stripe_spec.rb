require 'rails_helper'

RSpec.describe "Webhooks::Stripes", type: :request do
  describe "POST /webhooks/stripe" do
    it "returns 400 when the signature is missing/invalid" do
      post "/webhooks/stripe", params: "{}"
      expect(response).to have_http_status(:bad_request)
    end
  end
end
