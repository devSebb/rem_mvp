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

  it "rejects redemption attempts for gift cards that belong to another merchant" do
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

    get confirm_merchant_redemptions_path(
      gift_card_id: other_gift_card.id,
      redemption_mode: "token",
      redemption_token: formatted_token
    )

    expect(response).to redirect_to(new_merchant_redemption_path)
    expect(flash[:alert]).to eq("This gift card is not redeemable by your store.")
    expect(other_gift_card.reload.remaining_balance).to eq(5_000)
    token_record = RedemptionToken.find_by(token_digest: RedemptionToken.digest(other_token))
    expect(token_record&.used_at).to be_nil
  end
end
