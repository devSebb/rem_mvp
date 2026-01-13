require "rails_helper"

RSpec.describe "GiftCards", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { create(:user, address: "123 Main St", country_of_residence: "PE", date_of_birth: Date.new(1990, 1, 1)) }
  let!(:merchant) { create(:merchant) }
  let(:endpoint) { "/gift_cards/checkout" }
  let(:base_params) do
    {
      amount_cents: "10", # dollars, converted to cents server-side
      currency: "USD",
      recipient_email: "test@example.com",
      recipient_name: "Tester",
      merchant_id: merchant.id
    }
  end

  before { sign_in user }

  describe "POST /gift_cards/checkout" do
    context "when KYC details are missing" do
      let(:user) { create(:user, address: nil, country_of_residence: nil, date_of_birth: nil) }

      it "redirects to new gift card page without creating a Stripe session" do
        expect(Stripe::Checkout::Session).not_to receive(:create)

        post endpoint, params: base_params

        expect(response).to redirect_to(new_gift_card_path)
        expect(flash[:alert]).to include("complete your details")
      end
    end

    it "rejects missing merchant_id" do
      expect(Stripe::Checkout::Session).not_to receive(:create)

      post endpoint, params: base_params.merge(merchant_id: "")

      expect(response).to redirect_to(new_gift_card_path)
      expect(flash[:alert]).to eq("Merchant is required")
    end

    it "rejects invalid merchant_id" do
      expect(Stripe::Checkout::Session).not_to receive(:create)

      post endpoint, params: base_params.merge(merchant_id: "abc")

      expect(response).to redirect_to(new_gift_card_path)
      expect(flash[:alert]).to eq("Please select a valid merchant")
    end

    it "rejects unknown merchant_id" do
      expect(Stripe::Checkout::Session).not_to receive(:create)

      post endpoint, params: base_params.merge(merchant_id: merchant.id + 10_000)

      expect(response).to redirect_to(new_gift_card_path)
      expect(flash[:alert]).to eq("Please select a valid merchant")
    end

    it "creates a Stripe checkout session when merchant is valid" do
      session_double = instance_double(Stripe::Checkout::Session, url: "https://stripe.test/checkout")
      expect(Stripe::Checkout::Session).to receive(:create).with(
        hash_including(
          metadata: hash_including(merchant_id: merchant.id)
        )
      ).and_return(session_double)

      post endpoint, params: base_params

      expect(response).to redirect_to(session_double.url)
    end
  end
end
