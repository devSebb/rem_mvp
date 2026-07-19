require "rails_helper"

# Merchant redemption reversals (Type A) must reduce every money surface:
# what merchants see as pending, what admin pays out, and what settlements
# reconcile to. Stripe buyer refunds (Type B) must never affect them.
RSpec.describe "Reversal netting", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:merchant_user) { create(:user, role: :merchant) }
  let(:merchant) { create(:merchant, user: merchant_user) }
  let(:admin) { create(:user, role: :admin) }
  let(:buyer) { create(:user) }

  def redeem!(gift_card, cents, at: Time.current)
    txn = gift_card.transactions.create!(
      amount: cents, txn_type: :redemption, status: :succeeded, currency: "USD",
      processor_ref: "ui_redemption_#{SecureRandom.hex(6)}", merchant: merchant,
      user: merchant_user, created_at: at
    )
    gift_card.update!(remaining_balance: gift_card.remaining_balance - cents)
    gift_card.update!(status: :redeemed, redeemed_at: at) if gift_card.remaining_balance.zero?
    txn
  end

  def reverse!(redemption)
    Refunds::Issue.call(
      merchant: merchant, redemption_transaction_id: redemption.id,
      actor: merchant_user, reason: "spec", idempotency_key: nil
    )
  end

  let(:gift_card) { create(:gift_card, sender: buyer, recipient: buyer, merchant: merchant, amount: 1_000) }

  describe "central helpers" do
    it "nets reversals out of redeemed totals" do
      redemption = redeem!(gift_card, 1_000)
      expect(Transaction.net_redeemed_cents(merchant_id: merchant.id)).to eq(1_000)

      reverse!(redemption)
      expect(Transaction.net_redeemed_cents(merchant_id: merchant.id)).to eq(0)
      expect(Transaction.net_redeemed_cents_by_merchant[merchant.id]).to eq(0)
      expect(merchant.unsettled_net_redeemed_cents).to eq(0)
    end

    it "re-spend after reversal counts exactly once" do
      first = redeem!(gift_card, 1_000)
      reverse!(first)
      redeem!(gift_card.reload, 1_000)

      expect(Transaction.net_redeemed_cents(merchant_id: merchant.id)).to eq(1_000)
      expect(merchant.unsettled_net_redeemed_cents).to eq(1_000)
    end

    it "ignores Stripe buyer refunds (Type B)" do
      redeem!(gift_card, 400)
      gift_card.transactions.create!(
        amount: 600, txn_type: :refund, status: :succeeded, currency: "USD",
        processor_ref: "re_typeb_#{SecureRandom.hex(4)}", merchant: merchant,
        metadata: { stripe_refund_id: "re_typeb_1" }
      )

      expect(Transaction.net_redeemed_cents(merchant_id: merchant.id)).to eq(400)
    end

    it "blocks a second reversal of the same redemption at the DB level" do
      redemption = redeem!(gift_card, 1_000)
      reverse!(redemption)

      expect {
        Transaction.create!(
          gift_card: gift_card, merchant: merchant, amount: 1_000, currency: "USD",
          txn_type: :refund, status: :succeeded, processor_ref: "refund_dup_#{SecureRandom.hex(4)}",
          reversal_of_transaction_id: redemption.id
        )
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "admin payout creation" do
    before { sign_in admin }

    it "pays net of reversals made before the payout" do
      redeem!(gift_card, 1_000)
      second_card = create(:gift_card, sender: buyer, recipient: buyer, merchant: merchant, amount: 500)
      reversed = redeem!(second_card, 500)
      reverse!(reversed)

      post admin_payouts_path(merchant_id: merchant.id)

      settlement = Settlement.last
      expect(settlement.gross_amount).to eq(1_000)
      expect(settlement.amount).to eq(1_000)
      expect(settlement.calculated_amount).to eq(1_000)
      expect(settlement.amount_matches_calculated?).to be(true)
    end

    it "a reversal AFTER a paid settlement reduces the next payout" do
      first = redeem!(gift_card, 1_000, at: 10.days.ago)
      travel_to(5.days.ago) { post admin_payouts_path(merchant_id: merchant.id) }
      Settlement.last.update!(payout_status: :paid, paid_at: 5.days.ago)
      expect(Settlement.last.amount).to eq(1_000)

      # Card is drained; reverse the paid-out redemption, then a new $300 redemption arrives
      reverse!(first)
      second_card = create(:gift_card, sender: buyer, recipient: buyer, merchant: merchant, amount: 300)
      redeem!(second_card, 300)

      expect(merchant.unsettled_net_redeemed_cents).to eq(-700)

      post admin_payouts_path(merchant_id: merchant.id)
      expect(Settlement.count).to eq(1) # blocked — no new settlement
      expect(flash[:alert]).to include("reversas superan")
    end

    it "blocks payout when reversals exceed unsettled redemptions" do
      first = redeem!(gift_card, 1_000, at: 10.days.ago)
      travel_to(5.days.ago) { post admin_payouts_path(merchant_id: merchant.id) }
      reverse!(first)

      post admin_payouts_path(merchant_id: merchant.id)

      expect(Settlement.count).to eq(1)
      expect(flash[:alert]).to include("reversas superan")
    end
  end

  describe "merchant dashboard" do
    before { sign_in merchant_user }

    it "shows pending settlement net of reversals and excluding settled periods" do
      old = redeem!(gift_card, 1_000, at: 10.days.ago)
      sign_in admin
      travel_to(5.days.ago) { post admin_payouts_path(merchant_id: merchant.id) }
      sign_in merchant_user

      second_card = create(:gift_card, sender: buyer, recipient: buyer, merchant: merchant, amount: 500)
      newer = redeem!(second_card, 500)
      reverse!(newer)

      get merchant_root_path

      expect(response).to have_http_status(:ok)
      # settled $10 excluded; new $5 redeemed and $5 reversed → $0.00 pending
      expect(response.body).to include("Liquidación pendiente")
      expect(assigns_pending(response)).to eq("$0.00")
    end

    def assigns_pending(response)
      response.body[/Liquidación pendiente.*?(\$[\d,.]+)/m, 1]
    end
  end

  describe "merchant settlements summaries" do
    it "nets reversals per gift card" do
      redemption = redeem!(gift_card, 1_000)
      reverse!(redemption)

      summary = SettlementService.gift_card_settlement_summary_for_redeemer(gift_card, merchant)
      expect(summary[:total_redeemed]).to eq(0)
      expect(summary[:remaining_to_settle]).to eq(0)
      expect(summary[:settlement_status]).to eq("settled")
    end
  end
end
