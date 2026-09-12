require "rails_helper"
require "nokogiri"

RSpec.describe "Merchant::Redemptions", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:merchant_user) { create(:user, role: :merchant) }
  let(:group) { create(:redemption_group, name: "Farmaenlace") }
  let!(:merchant) { create(:merchant, user: merchant_user, redemption_group: group) }
  let(:other_merchant) { create(:merchant, redemption_group: group) } # same group → allowed (D6)
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

  before do
    sign_in merchant_user
    allow(Messaging::RedemptionPusher).to receive(:call)
  end

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

    expect(response).to redirect_to(success_merchant_redemptions_path(gift_card_id: gift_card.id, amount_cents: 1_000))
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
    expect(response.body).not_to include("Canje en red") # D6: group membership is silent, mismatch is a decline
    expect(response.body).to include(other_merchant.store_name)

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

    expect(response).to redirect_to(success_merchant_redemptions_path(gift_card_id: other_gift_card.id, amount_cents: 2_000))
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

  it "declines a card issued for a merchant outside the redemption group (D6)" do
    outsider = create(:merchant) # no group
    outsider_card = create(:gift_card, sender: sender, recipient: create(:user), merchant: outsider, amount: 5_000)
    outsider_token = RedemptionTokens::Issue.call(gift_card: outsider_card)[:token]

    post merchant_redemptions_path, params: { code: outsider_token }
    expect(response).to redirect_to(new_merchant_redemption_path)
    expect(flash[:alert]).to include(outsider.store_name)

    get confirm_merchant_redemptions_path(gift_card_id: outsider_card.id, redemption_mode: "token", redemption_token: outsider_token)
    expect(response).to redirect_to(new_merchant_redemption_path)
    expect(outsider_card.reload.remaining_balance).to eq(5_000)
  end

  it "shows spendable, not total, when part of the balance is held (§5.4)" do
    stripe_load!(gift_card, 3_000, sender: sender, held_until: 2.hours.from_now)

    get confirm_merchant_redemptions_path(gift_card_id: gift_card.id, redemption_mode: "token", redemption_token: token_value_with_hyphens)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Saldo disponible")
    expect(response.body).to include("$50.00") # spendable
    expect(response.body).to include("$80.00") # total
    expect(response.body).to include("en revisión")
  end

  it "rejects static gift-card codes in the merchant UI" do
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

    post merchant_redemptions_path, params: { code: static_code }

    expect(response).to redirect_to(new_merchant_redemption_path)
    expect(other_gift_card.reload.remaining_balance).to eq(5_000)
    expect(other_gift_card.transactions.redemptions.succeeded).to be_empty
  end
end
