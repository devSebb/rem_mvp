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
        redeem_card!(gift_card, 19_000, merchant: gift_card.merchant) # $190 already redeemed

        expect(Stripe::Refund).not_to receive(:create)
        post admin_gift_card_refunds_path(gift_card),
             params: { refund_amount: "200.00", reason: "full refund attempt" }

        load = gift_card.loads.sole
        expect(response.location).to eq("http://www.example.com#{new_admin_gift_card_load_refund_path(gift_card, load)}")
        expect(flash[:alert]).to include("excede")
      end

      it "issues a refund within the refundable balance" do
        refund = OpenStruct.new(id: "re_req_ok", amount: 1_000, currency: "usd")
        expect(Stripe::Refund).to receive(:create).and_return(refund)

        redeem_card!(gift_card, 19_000, merchant: gift_card.merchant)
        post admin_gift_card_refunds_path(gift_card),
             params: { refund_amount: "10.00", reason: "customer request" }

        expect(response).to redirect_to(admin_gift_card_path(gift_card))
        expect(flash[:notice]).to include("re_req_ok")
      end

      it "refunds the chosen load through the per-load route (§9)" do
        second = stripe_load!(gift_card, 4_000, sender: create(:user), payment_intent_id: "pi_req_second")
        refund = OpenStruct.new(id: "re_req_load2", amount: 1_500, currency: "usd")
        expect(Stripe::Refund).to receive(:create).with(hash_including(payment_intent: "pi_req_second", amount: 1_500), anything).and_return(refund)

        get new_admin_gift_card_load_refund_path(gift_card, second)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Seleccionada")

        post admin_gift_card_load_refund_path(gift_card, second),
             params: { refund_amount: "15.00", reason: "buyer asked" }

        expect(response).to redirect_to(admin_gift_card_path(gift_card))
        expect(flash[:notice]).to include("re_req_load2").and include("##{second.id}")
      end
    end
  end
end
