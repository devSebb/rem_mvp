require "rails_helper"
require "nokogiri"

RSpec.describe "Merchant::Redemptions", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:merchant_user) { create(:user, role: :merchant) }
  let!(:merchant) { create(:merchant, user: merchant_user) }
let(:other_merchant) { create(:merchant) }
  let(:recipient) { create(:user) }
  let(:sender) { create(:user) }
  let!(:gift_card) do
    create(
      :gift_card,
      sender: sender,
      recipient: recipient,
      merchant: merchant,
      amount: 5_000,
      remaining_balance: 5_000,
      status: :active
    )
  end
  let!(:token_value) { RedemptionTokens::Issue.call(gift_card: gift_card)[:token] }
  let(:token_value_with_hyphens) { token_value.scan(/.{1,4}/).join("-") }

  before { sign_in merchant_user }

  it "redeems a gift card using the dynamic token via the merchant UI" do
    get confirm_merchant_redemptions_path(
      gift_card_id: gift_card.id,
      redemption_mode: "token",
      redemption_token: token_value_with_hyphens
    )
    expect(response).to have_http_status(:ok)

    doc = Nokogiri::HTML(response.body)
    idempotency = doc.at_css("input[name='idempotency_token']")&.[]("value")
    expect(idempotency).to be_present

    post redeem_merchant_redemptions_path, params: {
      gift_card_id: gift_card.id,
      redemption_mode: "token",
      redemption_token: token_value_with_hyphens,
      redemption_amount: 10, # dollars
      idempotency_token: idempotency
    }

    expect(response).to redirect_to(success_merchant_redemptions_path(gift_card_id: gift_card.id))
    expect(gift_card.reload.remaining_balance).to eq(4_000)

    token_record = RedemptionToken.find_by(token_digest: RedemptionToken.digest(token_value))
    expect(token_record&.used_at).to be_present

    redemption_txn = gift_card.transactions.redemptions.succeeded.last
    expect(redemption_txn).to be_present
    expect(redemption_txn.redemption_token_id).to eq(token_record.id)
  end

  it "allows cross-merchant redemption (network redemption) via token mode" do
    other_gift_card = create(
      :gift_card,
      sender: sender,
      recipient: recipient,
      merchant: other_merchant,
      amount: 5_000,
      remaining_balance: 5_000,
      status: :active
    )
    other_token = RedemptionTokens::Issue.call(gift_card: other_gift_card)[:token]
    formatted_token = other_token.scan(/.{1,4}/).join("-")

    # Confirm page should load successfully for another merchant's gift card
    get confirm_merchant_redemptions_path(
      gift_card_id: other_gift_card.id,
      redemption_mode: "token",
      redemption_token: formatted_token
    )
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Canje en red") # Cross-merchant indicator

    doc = Nokogiri::HTML(response.body)
    idempotency = doc.at_css("input[name='idempotency_token']")&.[]("value")
    expect(idempotency).to be_present

    # Redeem should complete successfully
    post redeem_merchant_redemptions_path, params: {
      gift_card_id: other_gift_card.id,
      redemption_mode: "token",
      redemption_token: formatted_token,
      redemption_amount: 20, # dollars
      idempotency_token: idempotency
    }

    expect(response).to redirect_to(success_merchant_redemptions_path(gift_card_id: other_gift_card.id))
    expect(other_gift_card.reload.remaining_balance).to eq(3_000) # 5000 - 2000

    # Token should be marked as used
    token_record = RedemptionToken.find_by(token_digest: RedemptionToken.digest(other_token))
    expect(token_record&.used_at).to be_present

    # Transaction should record the REDEEMING merchant (not issuing merchant)
    redemption_txn = other_gift_card.transactions.redemptions.succeeded.last
    expect(redemption_txn).to be_present
    expect(redemption_txn.merchant_id).to eq(merchant.id) # Redeemer is logged-in merchant
    expect(redemption_txn.merchant_id).not_to eq(other_merchant.id) # NOT the issuing merchant
  end

  it "allows cross-merchant redemption via static code mode" do
    other_gift_card = create(
      :gift_card,
      sender: sender,
      recipient: recipient,
      merchant: other_merchant,
      amount: 5_000,
      remaining_balance: 5_000,
      status: :active
    )
    static_code = other_gift_card.raw_code

    # Confirm page should load successfully for another merchant's gift card (code mode)
    get confirm_merchant_redemptions_path(
      gift_card_id: other_gift_card.id,
      redemption_mode: "code"
    )
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Canje en red") # Cross-merchant indicator

    doc = Nokogiri::HTML(response.body)
    idempotency = doc.at_css("input[name='idempotency_token']")&.[]("value")
    expect(idempotency).to be_present

    # Redeem should complete successfully
    post redeem_merchant_redemptions_path, params: {
      gift_card_id: other_gift_card.id,
      redemption_mode: "code",
      redemption_amount: 15, # dollars
      idempotency_token: idempotency
    }

    expect(response).to redirect_to(success_merchant_redemptions_path(gift_card_id: other_gift_card.id))
    expect(other_gift_card.reload.remaining_balance).to eq(3_500) # 5000 - 1500

    # Transaction should record the REDEEMING merchant
    redemption_txn = other_gift_card.transactions.redemptions.succeeded.last
    expect(redemption_txn).to be_present
    expect(redemption_txn.merchant_id).to eq(merchant.id) # Redeemer
  end
end
