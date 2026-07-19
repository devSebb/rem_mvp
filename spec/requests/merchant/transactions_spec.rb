require "rails_helper"

RSpec.describe "Merchant::Transactions", type: :request do
  let(:merchant_user) { create(:user, role: :merchant) }
  let(:merchant) { create(:merchant, user: merchant_user) }
  let(:buyer) { create(:user) }

  let(:gift_card) do
    create(:gift_card, sender: buyer, recipient: buyer, merchant: merchant, amount: 500)
  end

  let!(:redemption) do
    txn = gift_card.transactions.create!(
      amount: 500, txn_type: :redemption, status: :succeeded, currency: "USD",
      processor_ref: "ui_redemption_#{SecureRandom.hex(4)}", merchant: merchant, user: merchant_user
    )
    gift_card.update!(remaining_balance: 0, status: :redeemed, redeemed_at: Time.current)
    txn
  end

  before { sign_in merchant_user }

  describe "POST /merchant/gift_cards/:gift_card_id/transactions/:transaction_id/refund" do
    it "reverses the redemption and restores the card balance" do
      post merchant_gift_card_refund_transaction_path(gift_card, redemption.id)

      expect(response).to redirect_to(merchant_gift_card_path(gift_card))
      follow_redirect!
      expect(response.body).to include("Reembolso realizado correctamente")

      gift_card.reload
      expect(gift_card.remaining_balance).to eq(500)
      expect(gift_card.status).to eq("active")
      expect(gift_card.transactions.refunds.succeeded.count).to eq(1)
    end

    it "rejects a double refund with a flash, not a 500" do
      post merchant_gift_card_refund_transaction_path(gift_card, redemption.id)
      post merchant_gift_card_refund_transaction_path(gift_card, redemption.id)

      expect(response).to redirect_to(merchant_gift_card_path(gift_card))
      expect(flash[:alert]).to include("already refunded")
      expect(gift_card.reload.remaining_balance).to eq(500)
    end

    it "rejects a transaction belonging to another merchant" do
      other_merchant = create(:merchant)
      other_card = create(:gift_card, merchant: other_merchant)
      other_txn = other_card.transactions.create!(
        amount: 100, txn_type: :redemption, status: :succeeded, currency: "USD",
        processor_ref: "ui_redemption_#{SecureRandom.hex(4)}", merchant: other_merchant
      )

      post merchant_gift_card_refund_transaction_path(other_card, other_txn.id)

      expect(response).to redirect_to(merchant_root_path)
    end

    it "blocks non-merchant users" do
      sign_in buyer

      post merchant_gift_card_refund_transaction_path(gift_card, redemption.id)

      expect(response).to redirect_to(root_path)
    end
  end
end
