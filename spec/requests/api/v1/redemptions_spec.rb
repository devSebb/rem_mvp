require "rails_helper"

RSpec.describe "Api::V1::Redemptions", type: :request do
  let(:merchant_secret) { "sec_test_key_123" }
  let(:other_merchant_secret) { "sec_other_key_456" }
  let(:merchant) { create_merchant(secret: merchant_secret) }
  let(:other_merchant) { create_merchant(secret: other_merchant_secret) }
  let(:gift_card) { create_gift_card(merchant:) }
  let(:raw_token) { issue_token_for(gift_card) }

  describe "POST /api/v1/redemptions" do
    it "returns forbidden when attempting to redeem another merchant's gift card" do
      other_merchant # ensure created

      expect {
        post "/api/v1/redemptions",
             params: {
               token: raw_token,
               amount_cents: 1_000,
               idempotency_key: SecureRandom.uuid
             }.to_json,
             headers: auth_headers(other_merchant_secret)
      }.not_to change { Transaction.count }

      expect(response).to have_http_status(:forbidden)
      body = JSON.parse(response.body)
      expect(body["approved"]).to be(false)
      expect(body["decline_reason"]).to eq("merchant_mismatch")
      expect(body["transaction_id"]).to be_nil
      expect(body["gift_card_id"]).to eq(gift_card.id)
      expect(body["remaining_balance_cents"]).to eq(gift_card.amount)

      expect(gift_card.reload.remaining_balance).to eq(10_000)
      token_record = RedemptionToken.find_by(token_digest: RedemptionToken.digest(raw_token))
      expect(token_record&.used_at).to be_nil
    end
  end

  def auth_headers(secret)
    merchant
    {
      "Authorization" => "Bearer #{secret}",
      "Content-Type" => "application/json"
    }
  end

  def create_merchant(secret:)
    Merchant.create!(
      user: create_user(role: :merchant),
      store_name: "Demo Store #{SecureRandom.hex(2)}",
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
      role: role,
      national_id: "TEST#{SecureRandom.hex(4)}".upcase
    )
  end

  def create_gift_card(merchant:)
    sender = create_user(role: :user)
    GiftCard.create!(
      sender:,
      recipient: sender,
      merchant:,
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

