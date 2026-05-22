require "rails_helper"

RSpec.describe "GiftCards", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { create(:user, address: "123 Main St", country_of_residence: "PE", date_of_birth: Date.new(1990, 1, 1)) }
  let!(:merchant) { create(:merchant) }

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

end
