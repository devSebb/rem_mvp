require "rails_helper"

RSpec.describe "Webhooks::Stripes", type: :request do
  describe "POST /webhooks/stripe" do
    it "returns 400 when the signature is missing/invalid" do
      post "/webhooks/stripe", params: "{}"
      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)).to include("error")
    end

    it "returns response contract: 200 with status success when signature is valid" do
      event = double("Stripe::Event", type: "ping", data: double(object: {}))
      allow(StripeWebhooks).to receive(:verify_signature) do |payload, sig|
        (payload.present? && sig == "v1,sig") ? event : false
      end
      allow(StripeWebhooks).to receive(:process_event).with(event)

      post "/webhooks/stripe",
           params: { type: "ping" }.to_json,
           headers: { "Stripe-Signature" => "v1,sig", "Content-Type" => "application/json" }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq("status" => "success")
    end
  end
end
