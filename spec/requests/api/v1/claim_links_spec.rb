require "rails_helper"

# §8.2: the teaser resolves a LOAD — that load's sender, amount, note and
# the card's merchant; never a code, contact detail or card balance.
RSpec.describe "Api::V1 ClaimLinks teaser", type: :request do
  let(:sender) { create(:user, first_name: "Ana") }
  let(:recipient) { create(:user, phone: "+593999123456") }
  let(:merchant) { create(:merchant, store_name: "Medicity") }
  let!(:gift_card) { create(:gift_card, recipient:, merchant:, amount: 0) }
  let!(:load) { stripe_load!(gift_card, 2_500, sender: sender, note: "Feliz cumple") }
  let(:token) { GiftCards::ClaimLink.issue!(load) }

  describe "GET /api/v1/claim/:token" do
    it "returns the public teaser without authentication" do
      get "/api/v1/claim/#{token}"

      expect(response).to have_http_status(:ok)

      data = parsed_data
      expect(data["gift_card_id"]).to eq(gift_card.id)
      expect(data["load_id"]).to eq(load.id)
      expect(data["status"]).to eq("active")
      expect(data["load_status"]).to eq("available")
      expect(data["is_reload"]).to be(false)
      expect(data["amount_cents"]).to eq(2500)
      expect(data["currency"]).to eq("USD")
      expect(data["merchant_name"]).to eq("Medicity")
      expect(data["sender_first_name"]).to eq("Ana")
      expect(data["note"]).to eq("Feliz cumple")
      expect(data["recipient_masked_phone"]).to eq("+593•••3456")
      expect(data["recipient_registered"]).to be(true)
      expect(data["teaser"]).to eq("Ana te envió una tarjeta de regalo digital de Medicity · $25.00")
    end

    it "describes a reload as a reload with that load's amount" do
      luis = create(:user, first_name: "Luis")
      reload = stripe_load!(gift_card, 1_000, sender: luis, note: nil)

      get "/api/v1/claim/#{GiftCards::ClaimLink.issue!(reload)}"

      data = parsed_data
      expect(data["is_reload"]).to be(true)
      expect(data["amount_cents"]).to eq(1_000)
      expect(data["sender_first_name"]).to eq("Luis")
      expect(data["note"]).to be_nil
      expect(data["teaser"]).to eq("Luis recargó tu tarjeta de Medicity con $10.00")
    end

    it "never exposes anything redeemable, personal or the card balance" do
      get "/api/v1/claim/#{token}"

      data = parsed_data
      expect(data.keys).not_to include(
        "code", "raw_code", "code_digest", "recipient_id", "sender_id",
        "recipient_phone", "recipient_email", "remaining_balance_cents", "spendable_cents", "card_spendable_cents"
      )
      expect(response.body).not_to include(recipient.phone)
      expect(response.body).not_to include(recipient.email)
    end

    it "returns 404 for an unknown token" do
      get "/api/v1/claim/deadbeefdeadbeefdeadbeefdeadbeef"

      expect(response).to have_http_status(:not_found)
      expect(parsed_error["code"]).to eq("claim_link.not_found")
    end

    it "returns 404 once the link has expired" do
      token # issue before expiring
      load.update_columns(link_token_expires_at: 1.minute.ago)

      get "/api/v1/claim/#{token}"

      expect(response).to have_http_status(:not_found)
      expect(parsed_error["code"]).to eq("claim_link.not_found")
    end
  end

  def parsed_body
    JSON.parse(response.body)
  end

  def parsed_data
    parsed_body["data"]
  end

  def parsed_error
    parsed_body["error"] || {}
  end
end
