require "rails_helper"

# §8.2 consumer endpoints: /me/gift_cards/:id/loads, /me/loads?role=sent,
# /me/activity; §8.3 redemption_token 422s; §5.10 policy scope.
RSpec.describe "Api::V1 loads, sent list, activity and redemption token", type: :request do
  let(:password) { "Password!23" }
  let(:json_headers) { { "Content-Type" => "application/json" } }
  let(:recipient) { create(:user, password:, first_name: "Rita") }
  let(:ana) { create(:user, password:, first_name: "Ana") }
  let(:luis) { create(:user, password:, first_name: "Luis") }
  let(:merchant) { create(:merchant, store_name: "Medicity") }
  let!(:card) { create(:gift_card, recipient:, merchant:, amount: 0) }
  let!(:load_a) { stripe_load!(card, 3_000, sender: ana, at: 3.days.ago, note: "Feliz cumple") }
  let!(:load_b) { stripe_load!(card, 2_000, sender: luis, at: 2.days.ago) }

  describe "GET /api/v1/me/gift_cards" do
    it "lists the card for the recipient and for every buyer, with §8.1 fields" do
      [recipient, ana, luis].each do |u|
        get "/api/v1/me/gift_cards", headers: auth_headers(access_token_for(u))
        expect(response).to have_http_status(:ok)
        expect(parsed_data.map { |c| c["id"] }).to eq([card.id])
      end

      c = parsed_data.first
      expect(c).to include("spendable_cents" => 5_000, "remaining_balance_cents" => 5_000, "amount_cents" => 5_000,
                           "total_loaded_cents" => 5_000, "loads_count" => 2, "status" => "active")
      expect(c["sender_id"]).to eq(luis.id) # COMPAT: latest load's sender
      expect(c["loads"].map { |l| l["id"] }).to eq([load_b.id, load_a.id])
      expect(c["loads"].last).to include("note" => "Feliz cumple", "is_self" => false)
    end

    it "hides the card from strangers" do
      get "/api/v1/me/gift_cards", headers: auth_headers(access_token_for(create(:user, password:)))
      expect(parsed_data).to eq([])
      get "/api/v1/me/gift_cards/#{card.id}", headers: auth_headers(access_token_for(create(:user, password:)))
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/me/gift_cards/:id/loads" do
    it "gives the recipient every load, newest first, paginated" do
      get "/api/v1/me/gift_cards/#{card.id}/loads", params: { per_page: 1 }, headers: auth_headers(access_token_for(recipient))

      expect(response).to have_http_status(:ok)
      expect(parsed_data).to include("gift_card_id" => card.id, "page" => 1, "per_page" => 1, "total_count" => 2, "has_more" => true)
      expect(parsed_data["loads"].map { |l| l["id"] }).to eq([load_b.id])

      get "/api/v1/me/gift_cards/#{card.id}/loads", params: { per_page: 1, page: 2 }, headers: auth_headers(access_token_for(recipient))
      expect(parsed_data["loads"].map { |l| l["id"] }).to eq([load_a.id])
      expect(parsed_data["has_more"]).to be(false)
    end

    it "gives a buyer only the loads they paid for" do
      get "/api/v1/me/gift_cards/#{card.id}/loads", headers: auth_headers(access_token_for(ana))

      expect(parsed_data["loads"].map { |l| l["id"] }).to eq([load_a.id])
      expect(parsed_data["total_count"]).to eq(1)
    end
  end

  describe "GET /api/v1/me/loads?role=sent" do
    it "lists the buyer's loads with card summary, masked recipient, claim_status and refundable_cents" do
      redeem_card!(card, 500, merchant: merchant) # FIFO → from load_a
      recipient.update!(phone: "+593999123456")

      get "/api/v1/me/loads", params: { role: "sent" }, headers: auth_headers(access_token_for(ana))

      expect(response).to have_http_status(:ok)
      expect(parsed_data["role"]).to eq("sent")
      row = parsed_data["loads"].sole
      expect(row).to include("id" => load_a.id, "amount_cents" => 3_000, "remaining_cents" => 2_500,
                             "refundable_cents" => 2_500, "claim_status" => "claimed")
      expect(row["recipient"]).to include("name" => "Rita", "masked_phone" => "+593•••3456", "registered" => true)
      expect(row["recipient"]).not_to have_key("phone")
      expect(row["gift_card"]).to include("id" => card.id, "spendable_cents" => 4_500, "loads_count" => 2)
      expect(row["gift_card"]["merchant"]).to include("store_name" => "Medicity")
    end

    it "marks pending recipients and rejects other roles" do
      pending = User.create!(name: "Pendiente", email: User.placeholder_email_for_phone("+15550001111"), phone: "+15550001111",
                             password: SecureRandom.hex(16), role: :user, pending_recipient: true, skip_national_id_validation: true)
      pcard = create(:gift_card, recipient: pending, merchant: merchant, amount: 0)
      stripe_load!(pcard, 1_000, sender: ana)

      get "/api/v1/me/loads", params: { role: "sent" }, headers: auth_headers(access_token_for(ana))
      statuses = parsed_data["loads"].to_h { |l| [l["gift_card_id"], l["claim_status"]] }
      expect(statuses).to eq(card.id => "claimed", pcard.id => "pending_claim")

      get "/api/v1/me/loads", params: { role: "received" }, headers: auth_headers(access_token_for(ana))
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "GET /api/v1/me/activity" do
    it "builds the recipient's feed newest first with cursor pagination" do
      redemption = redeem_card!(card, 1_200, merchant: merchant, at: 1.day.ago)
      Refunds::Issue.call(merchant: merchant, redemption_transaction_id: redemption.id)

      get "/api/v1/me/activity", params: { limit: 2 }, headers: auth_headers(access_token_for(recipient))
      expect(response).to have_http_status(:ok)
      first_page = parsed_data["events"]
      expect(first_page.map { |e| e["type"] }).to eq(%w[reversal redemption])
      expect(first_page.first).to include("amount_cents" => 1_200, "gift_card_id" => card.id)
      expect(first_page.first["merchant"]).to include("store_name" => "Medicity")
      expect(parsed_data["next_cursor"]).to be_present

      get "/api/v1/me/activity", params: { limit: 2, cursor: parsed_data["next_cursor"] }, headers: auth_headers(access_token_for(recipient))
      second_page = parsed_data["events"]
      expect(second_page.map { |e| e["type"] }).to eq(%w[load_received load_received])
      expect(second_page.first).to include("load_id" => load_b.id)
      expect(second_page.first["counterpart"]).to include("name" => "Luis")
      expect(parsed_data["next_cursor"]).to be_nil
    end

    it "shows a buyer their sent loads, self loads and Stripe refunds" do
      own = create(:gift_card, recipient: ana, merchant: create(:merchant), amount: 0)
      self_load = stripe_load!(own, 800, sender: ana, at: 1.hour.ago)
      Transaction.create!(gift_card: card, gift_card_load: load_a, merchant: merchant, amount: 300, txn_type: :refund, status: :succeeded,
                          currency: "USD", processor_ref: "re_act_1", metadata: { stripe_refund_id: "re_act_1", debited_cents: 300 })

      get "/api/v1/me/activity", headers: auth_headers(access_token_for(ana))

      types = parsed_data["events"].map { |e| [e["type"], e["load_id"]] }
      expect(types).to include(["load_sent", load_a.id], ["load_self", self_load.id], ["refund", load_a.id])
      expect(types).not_to include(["load_sent", load_b.id])
      sent = parsed_data["events"].find { |e| e["type"] == "load_sent" }
      expect(sent["counterpart"]).to include("name" => "Rita")
    end
  end

  describe "POST /api/v1/me/gift_cards/:id/redemption_token (§8.3)" do
    it "returns the token with spendable_cents for the recipient" do
      post "/api/v1/me/gift_cards/#{card.id}/redemption_token", headers: auth_headers(access_token_for(recipient))

      expect(response).to have_http_status(:ok)
      expect(parsed_data["token"]).to be_present
      expect(parsed_data["spendable_cents"]).to eq(5_000)
    end

    it "422s gift_card.no_spendable_balance when everything is held, with the hold details" do
      hold_until = 3.hours.from_now
      card.loads.each { |l| l.update!(held_until: hold_until) }

      post "/api/v1/me/gift_cards/#{card.id}/redemption_token", headers: auth_headers(access_token_for(recipient))

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_error["code"]).to eq("gift_card.no_spendable_balance")
      expect(parsed_error["details"]).to include("held_cents" => 5_000, "spendable_cents" => 0)
      expect(parsed_error["details"]["held_until"]).to be_present
    end

    it "422s gift_card.frozen for an admin-frozen card" do
      card.update!(status: :frozen_by_admin, frozen_reason: "fraud")

      post "/api/v1/me/gift_cards/#{card.id}/redemption_token", headers: auth_headers(access_token_for(recipient))

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_error["code"]).to eq("gift_card.frozen")
    end

    it "is forbidden for a buyer" do
      post "/api/v1/me/gift_cards/#{card.id}/redemption_token", headers: auth_headers(access_token_for(ana))
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /api/v1/gift_cards/by_payment_intent/:pi" do
    it "answers for the load's buyer even when they are not the card's first sender" do
      get "/api/v1/gift_cards/by_payment_intent/#{load_b.payment_intent_id}", headers: auth_headers(access_token_for(luis))

      expect(response).to have_http_status(:ok)
      expect(parsed_data["id"]).to eq(card.id)
      expect(parsed_data["load"]).to include("id" => load_b.id, "amount_cents" => 2_000, "sender_id" => luis.id)
      expect(parsed_data["top_up"]).to eq(parsed_data["load"])
      expect(parsed_data["loads_count"]).to eq(2)

      get "/api/v1/gift_cards/by_payment_intent/#{load_b.payment_intent_id}", headers: auth_headers(access_token_for(ana))
      expect(response).to have_http_status(:not_found) # ana did not pay load_b
    end
  end

  def access_token_for(login_user)
    post "/api/v1/auth/login", params: { email: login_user.email, password: password }.to_json, headers: json_headers
    expect(response).to have_http_status(:ok)
    parsed_data["access_token"]
  end

  def auth_headers(token)
    json_headers.merge("Authorization" => "Bearer #{token}")
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
