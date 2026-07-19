require "rails_helper"
require "ostruct"

RSpec.describe "Admin::Refunds", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:gift_card) { create(:gift_card, amount: 20_000, payment_intent_id: "pi_req_spec") }

  describe "POST /admin/gift_cards/:gift_card_id/refund" do
    it "blocks merchants — Stripe refunds are admin-only" do
      merchant_owner = gift_card.merchant.user
      merchant_owner.update!(role: :merchant)
      sign_in merchant_owner

      expect(Stripe::Refund).not_to receive(:create)
      post admin_gift_card_refunds_path(gift_card),
           params: { refund_amount: "10.00", reason: "test" }

      expect(response).to redirect_to(root_path)
    end

    context "as admin" do
      before { sign_in create(:user, role: :admin) }

      it "rejects refunds above the refundable (unredeemed) balance" do
        gift_card.update!(remaining_balance: 1_000) # $190 already redeemed

        expect(Stripe::Refund).not_to receive(:create)
        post admin_gift_card_refunds_path(gift_card),
             params: { refund_amount: "200.00", reason: "full refund attempt" }

        expect(response).to redirect_to(new_admin_gift_card_refund_path(gift_card))
        expect(flash[:alert]).to include("excede")
      end

      it "issues a refund within the refundable balance" do
        refund = OpenStruct.new(id: "re_req_ok", amount: 1_000, currency: "usd")
        expect(Stripe::Refund).to receive(:create).and_return(refund)

        gift_card.update!(remaining_balance: 1_000)
        post admin_gift_card_refunds_path(gift_card),
             params: { refund_amount: "10.00", reason: "customer request" }

        expect(response).to redirect_to(admin_gift_card_path(gift_card))
        expect(flash[:notice]).to include("re_req_ok")
      end
    end
  end
end
