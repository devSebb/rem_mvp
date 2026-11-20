require "rails_helper"

RSpec.describe "Merchant portal access control", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:merchant_user) { create(:user, role: :merchant) }
  let!(:merchant) { create(:merchant, user: merchant_user) }

  describe "suspended merchants" do
    before do
      merchant.update!(status: :suspended)
      sign_in merchant_user
    end

    it "are signed out and turned away from every portal page" do
      get merchant_root_path
      expect(response).to redirect_to(new_user_session_path)
      expect(flash[:alert]).to include("suspendido")

      # The session was ended, so the next request needs a fresh login.
      get merchant_profile_path
      expect(response).to redirect_to(new_user_session_path)
    end

    it "cannot submit a redemption" do
      card = create(:gift_card, merchant: merchant, amount: 5_000, remaining_balance: 5_000, status: :active)
      token = RedemptionTokens::Issue.call(gift_card: card)[:token]

      expect {
        post redeem_merchant_redemptions_path, params: {
          gift_card_id: card.id, redemption_amount: "10.00",
          idempotency_token: SecureRandom.uuid, redemption_token: token
        }
      }.not_to change(Transaction, :count)
      expect(card.reload.remaining_balance).to eq(5_000)
    end

    it "cannot change the payout bank account" do
      patch merchant_profile_path, params: { merchant: { bank_account_iban: "EC00ATTACKER" } }
      expect(merchant.reload.bank_account_iban).not_to eq("EC00ATTACKER")
    end
  end

  it "turns away a merchant-role user with no merchant record instead of erroring" do
    orphan = create(:user, role: :merchant)
    sign_in orphan
    get merchant_root_path
    expect(response).to redirect_to(root_path)
  end

  describe "redemption success page" do
    let(:other_merchant) { create(:merchant) }
    let(:own_card) { create(:gift_card, merchant: merchant, amount: 5_000, remaining_balance: 4_000, status: :active) }
    let(:foreign_card) { create(:gift_card, merchant: other_merchant, amount: 9_900, remaining_balance: 9_900, status: :active) }

    before do
      create(:transaction, gift_card: own_card, merchant: merchant, txn_type: :redemption, status: :succeeded, amount: 1_000)
      sign_in merchant_user
    end

    it "shows a card this merchant redeemed" do
      get success_merchant_redemptions_path(gift_card_id: own_card.id, amount_cents: 1_000)
      expect(response).to have_http_status(:ok)
    end

    it "refuses a card this merchant never redeemed" do
      get success_merchant_redemptions_path(gift_card_id: foreign_card.id)
      expect(response).to redirect_to(new_merchant_redemption_path)
      expect(response.body).not_to include(foreign_card.recipient.first_name)
    end

    it "refuses a card where this merchant's redemption attempt failed" do
      create(:transaction, gift_card: foreign_card, merchant: merchant, txn_type: :redemption, status: :failed, amount: 1_000)
      get success_merchant_redemptions_path(gift_card_id: foreign_card.id)
      expect(response).to redirect_to(new_merchant_redemption_path)
    end
  end

  describe "service-level suspension guard" do
    before { merchant.update!(status: :suspended) }

    it "Redemptions::AuthorizeAndCapture rejects a suspended merchant" do
      expect {
        Redemptions::AuthorizeAndCapture.call(merchant: merchant, raw_token: "ABCD1234EF", amount_cents: 100,
                                              idempotency_key: "k1", merchant_reference: nil)
      }.to raise_error(Redemptions::AuthorizeAndCapture::ValidationError, /suspended/)
    end

    it "Refunds::Issue rejects a suspended merchant" do
      expect {
        Refunds::Issue.call(merchant: merchant, redemption_transaction_id: 1, actor: merchant_user,
                            reason: "x", idempotency_key: nil)
      }.to raise_error(Refunds::Issue::ValidationError, /suspended/)
    end
  end
end
