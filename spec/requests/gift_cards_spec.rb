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

  describe "GET /gift_cards (wallet)" do
    it "returns 200 and wallet page content" do
      get "/gift_cards"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Mi Billetera", "Billetera")
    end

    it "returns wallet data as JSON with same contract (array, include sender/recipient/merchant)" do
      get "/gift_cards", as: :json
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/json")
      data = response.parsed_body
      expect(data).to be_an(Array)
      data.each do |card|
        expect(card).to have_key("id")
        expect(card).to have_key("amount")
        expect(card).to have_key("status")
        expect(card).to have_key("sender_id")
        expect(card).to have_key("recipient_id")
        expect(card).to have_key("sender")
        expect(card).to have_key("recipient")
        expect(card).to have_key("merchant")
      end
    end
  end

  describe "POST /gift_cards/checkout" do
    context "when KYC details are missing" do
      let(:user) { create(:user, address: nil, country_of_residence: nil, date_of_birth: nil) }

      it "redirects to profile edit with KYC section anchor without creating a Stripe session" do
        expect(Stripe::Checkout::Session).not_to receive(:create)

        post endpoint, params: base_params

        expect(response).to redirect_to(edit_user_registration_path(anchor: "kyc-section"))
        expect(flash[:alert]).to match(/completa tu perfil|complete your details/i)
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

    context "when amount exceeds maximum" do
      it "rejects amount greater than $200" do
        expect(Stripe::Checkout::Session).not_to receive(:create)

        post endpoint, params: base_params.merge(amount_cents: "201")

        expect(response).to redirect_to(new_gift_card_path)
        expect(flash[:alert]).to include("monto máximo")
        expect(flash[:alert]).to include("$200")
      end

      it "allows amount exactly $200" do
        session_double = instance_double(Stripe::Checkout::Session, url: "https://stripe.test/checkout")
        expect(Stripe::Checkout::Session).to receive(:create).and_return(session_double)

        post endpoint, params: base_params.merge(amount_cents: "200")

        expect(response).to redirect_to(session_double.url)
      end
    end

    context "when purchase limit is exceeded" do
      before do
        # Create 5 gift cards in the last 24 hours
        5.times do
          create(:gift_card, sender: user, merchant: merchant, created_at: 1.hour.ago)
        end
      end

      it "rejects checkout when user has reached 24h limit" do
        expect(Stripe::Checkout::Session).not_to receive(:create)

        post endpoint, params: base_params

        expect(response).to redirect_to(new_gift_card_path)
        expect(flash[:alert]).to include("límite")
        expect(flash[:alert]).to include("24 horas")
      end

      it "allows checkout when user has 4 purchases (under limit)" do
        # Delete one to have 4
        GiftCard.where(sender: user).last.destroy

        session_double = instance_double(Stripe::Checkout::Session, url: "https://stripe.test/checkout")
        expect(Stripe::Checkout::Session).to receive(:create).and_return(session_double)

        post endpoint, params: base_params

        expect(response).to redirect_to(session_double.url)
      end

      it "allows checkout when oldest purchase is more than 24 hours ago" do
        # Update the oldest gift card to be 25 hours ago (use update_column to bypass callbacks)
        oldest_card = GiftCard.where(sender: user).order(created_at: :asc).first
        oldest_card.update_column(:created_at, 25.hours.ago)

        session_double = instance_double(Stripe::Checkout::Session, url: "https://stripe.test/checkout")
        expect(Stripe::Checkout::Session).to receive(:create).and_return(session_double)

        post endpoint, params: base_params

        expect(response).to redirect_to(session_double.url)
      end

      it "does not count canceled gift cards toward limit" do
        # Cancel one gift card
        GiftCard.where(sender: user).first.update!(status: :canceled)

        session_double = instance_double(Stripe::Checkout::Session, url: "https://stripe.test/checkout")
        expect(Stripe::Checkout::Session).to receive(:create).and_return(session_double)

        post endpoint, params: base_params

        expect(response).to redirect_to(session_double.url)
      end
    end
  end
end
