require "rails_helper"

RSpec.describe "Api::V1::Redemption refunds", type: :request do
  let(:merchant_secret) { "sec_test_key_123" }
  let(:merchant) { create_merchant(secret: merchant_secret) }
  let(:gift_card) { create_gift_card(merchant:) }
  let(:raw_token) { issue_token_for(gift_card) }

  describe "POST /api/v1/redemptions/:id/refund" do
    it "refunds a successful redemption and restores the gift card balance (idempotent)" do
      redemption_txn_id = create_redemption!(amount_cents: 2_500, idempotency_key: "idem-redeem-1")
      expect(gift_card.reload.remaining_balance).to eq(7_500)

      post "/api/v1/redemptions/#{redemption_txn_id}/refund",
           params: { idempotency_key: "idem-refund-1", reason: "customer asked" }.to_json,
           headers: auth_headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["approved"]).to be(true)
      expect(body["status"]).to eq("succeeded")
      expect(body["refund_transaction_id"]).to be_present
      expect(body["original_transaction_id"]).to eq(redemption_txn_id)
      expect(body["gift_card_id"]).to eq(gift_card.id)
      expect(body["amount_cents"]).to eq(2_500)
      expect(body["remaining_balance_cents"]).to eq(10_000)

      refund_txn_id = body["refund_transaction_id"]
      refund_txn = Transaction.find(refund_txn_id)
      expect(refund_txn.refund?).to be(true)
      expect(refund_txn.metadata["refund_of_transaction_id"].to_s).to eq(redemption_txn_id.to_s)

      # Repeat with same idempotency_key -> should return same transaction and not change balance again
      post "/api/v1/redemptions/#{redemption_txn_id}/refund",
           params: { idempotency_key: "idem-refund-1", reason: "ignored" }.to_json,
           headers: auth_headers

      expect(response).to have_http_status(:ok)
      body2 = JSON.parse(response.body)
      expect(body2["refund_transaction_id"]).to eq(refund_txn_id)
      expect(gift_card.reload.remaining_balance).to eq(10_000)
    end

    it "returns 404 when attempting to refund a redemption belonging to another merchant" do
      redemption_txn_id = create_redemption!(amount_cents: 1_000, idempotency_key: "idem-redeem-2")

      other_secret = "sec_other_456"
      other_merchant = create_merchant(secret: other_secret)
      expect(other_merchant.id).not_to eq(merchant.id)

      post "/api/v1/redemptions/#{redemption_txn_id}/refund",
           params: { idempotency_key: "idem-refund-x" }.to_json,
           headers: auth_headers(other_secret)

      expect(response).to have_http_status(:not_found)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("Not Found")
    end

    it "rejects refunds for non-successful or non-redemption transactions" do
      # Create a failed redemption (invalid token)
      post "/api/v1/redemptions",
           params: { token: "INVALID", amount_cents: 500, idempotency_key: "idem-fail-1" }.to_json,
           headers: auth_headers

      expect(response).to have_http_status(:ok)
      failed_txn_id = JSON.parse(response.body)["transaction_id"]
      failed_txn = Transaction.find(failed_txn_id)
      expect(failed_txn.failed?).to be(true)

      post "/api/v1/redemptions/#{failed_txn_id}/refund",
           params: { idempotency_key: "idem-refund-fail-1" }.to_json,
           headers: auth_headers

      expect(response).to have_http_status(:unprocessable_entity)
      body = JSON.parse(response.body)
      expect(body["error"]).to match(/successful redemption/i)
    end
  end

  def auth_headers(secret = merchant_secret)
    merchant
    {
      "Authorization" => "Bearer #{secret}",
      "Content-Type" => "application/json"
    }
  end

  def create_redemption!(amount_cents:, idempotency_key:)
    post "/api/v1/redemptions",
         params: { token: raw_token, amount_cents: amount_cents, idempotency_key: idempotency_key }.to_json,
         headers: auth_headers

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["approved"]).to be(true)
    body["transaction_id"]
  end

  def create_merchant(secret:)
    Merchant.create!(
      user: create_user(role: :merchant),
      store_name: "Demo Store",
      name: "Demo Store",
      address: "123 Main Street",
      contact_email: "merchant-#{SecureRandom.hex(4)}@example.com",
      bank_account_iban: "US12345#{SecureRandom.hex(2)}",
      status: :active,
      public_key: "pub_#{SecureRandom.hex(8)}",
      secret_key_digest: Merchant.digest_secret(secret)
    )
  end

  def create_user(role:)
    User.create!(
      email: "#{role}-#{SecureRandom.hex(6)}@example.com",
      password: "Password!23",
      name: "#{role.to_s.capitalize} #{SecureRandom.hex(4)}",
      role: role
    )
  end

  def create_gift_card(merchant:)
    sender = create_user(role: :user)
    GiftCard.create!(
      sender: sender,
      merchant: merchant,
      amount: 10_000,
      remaining_balance: 10_000,
      currency: "USD",
      code_digest: BCrypt::Password.create(SecureRandom.hex(8)),
      status: :active,
      expires_at: 1.year.from_now
    )
  end

  def issue_token_for(gift_card)
    raw_token = SecureRandom.base58(10).upcase
    gift_card.redemption_tokens.create!(
      token_digest: RedemptionToken.digest(raw_token),
      expires_at: 5.minutes.from_now
    )
    raw_token
  end
end


