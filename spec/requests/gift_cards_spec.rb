require "rails_helper"

RSpec.describe "GiftCards", type: :request do
  include Devise::Test::IntegrationHelpers

  # The web wallet is gated to admins now (consumers are redirected to the
  # coming-soon page — see ConsumerWebGate), so the wallet contract is
  # exercised with an admin account.
  let(:user) { create(:user, role: :admin, address: "123 Main St", country_of_residence: "PE", date_of_birth: Date.new(1990, 1, 1)) }
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

    it "never leaks counterparty PII or merchant secrets in the wallet JSON" do
      counterparty = create(
        :user,
        national_id: "PII1712345678",
        date_of_birth: Date.new(1985, 5, 5),
        address: "Av. Amazonas 123, Quito",
        phone: "+593991234567"
      )
      create(:gift_card, sender: user, recipient: counterparty, merchant:)
      create(:gift_card, sender: counterparty, recipient: user, merchant:)

      get "/gift_cards", as: :json

      expect(response).to have_http_status(:ok)

      body = response.body
      # No PII attribute names…
      expect(body).not_to include(
        "national_id", "date_of_birth", "encrypted_password",
        "encrypted_raw_code", "secret_key_digest", "code_digest",
        "reset_password_token", "bank_account_iban"
      )
      # …and no PII values for the other person on the card.
      expect(body).not_to include(counterparty.national_id)
      expect(body).not_to include(counterparty.phone)
      expect(body).not_to include("Av. Amazonas 123")
      expect(body).not_to include("1985-05-05")

      data = response.parsed_body
      expect(data.length).to eq(2)
      data.each do |card|
        expect(card["sender"].keys).to match_array(%w[id name])
        expect(card["recipient"].keys).to match_array(%w[id name])
        expect(card["merchant"].keys).to match_array(%w[id store_name])
      end
    end
  end

end
