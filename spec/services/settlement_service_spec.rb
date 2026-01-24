require 'rails_helper'

RSpec.describe SettlementService do
  let(:merchant_a) { create(:merchant, store_name: "Merchant A (Issuer)") }
  let(:merchant_b) { create(:merchant, store_name: "Merchant B (Redeemer)") }
  let(:sender) { create(:user) }
  let(:recipient) { create(:user) }

  describe ".create_settlement_for_period" do
    it "creates settlement for transactions REDEEMED BY the merchant (not issued by)" do
      # Create a gift card issued by Merchant A
      gift_card = create(:gift_card, merchant: merchant_a, sender: sender, recipient: recipient, amount: 10000)

      # Merchant B redeems it (cross-merchant)
      create(:transaction,
        gift_card: gift_card,
        merchant: merchant_b,  # redeemer
        amount: 5000,
        txn_type: :redemption,
        status: :succeeded,
        currency: "USD",
        processor_ref: "test_1"
      )

      # Create settlement for Merchant B (redeemer)
      settlement = described_class.create_settlement_for_period(
        merchant_b,
        1.day.ago,
        1.day.from_now
      )

      expect(settlement).to be_present
      expect(settlement.merchant_id).to eq(merchant_b.id) # Settlement belongs to redeemer
      expect(settlement.amount).to eq(5000) # $50 redeemed
    end

    it "does NOT include transactions in settlement for the issuing merchant" do
      # Create a gift card issued by Merchant A
      gift_card = create(:gift_card, merchant: merchant_a, sender: sender, recipient: recipient, amount: 10000)

      # Merchant B redeems it
      create(:transaction,
        gift_card: gift_card,
        merchant: merchant_b,
        amount: 5000,
        txn_type: :redemption,
        status: :succeeded,
        currency: "USD",
        processor_ref: "test_2"
      )

      # Try to create settlement for Merchant A (issuer) - should be nil/empty
      settlement = described_class.create_settlement_for_period(
        merchant_a,
        1.day.ago,
        1.day.from_now
      )

      # Merchant A didn't redeem anything, so no settlement
      expect(settlement).to be_nil
    end

    it "only includes redemption transactions with succeeded status" do
      gift_card = create(:gift_card, merchant: merchant_a, amount: 10000)

      # Successful redemption
      create(:transaction, gift_card: gift_card, merchant: merchant_b, amount: 3000, txn_type: :redemption, status: :succeeded, currency: "USD", processor_ref: "t1")

      # Failed redemption (should not be included)
      create(:transaction, gift_card: gift_card, merchant: merchant_b, amount: 2000, txn_type: :redemption, status: :failed, currency: "USD", processor_ref: "t2")

      # Issuance transaction (should not be included)
      create(:transaction, gift_card: gift_card, merchant: merchant_b, amount: 10000, txn_type: :issuance, status: :succeeded, currency: "USD", processor_ref: "t3")

      settlement = described_class.create_settlement_for_period(merchant_b, 1.day.ago, 1.day.from_now)

      expect(settlement.amount).to eq(3000) # Only the successful redemption
    end
  end

  describe ".gift_card_settlement_summary_for_redeemer" do
    it "calculates summary from the redeemer's perspective" do
      # Create a gift card issued by Merchant A
      gift_card = create(:gift_card, merchant: merchant_a, sender: sender, recipient: recipient, amount: 10000)

      # Merchant B redeems part of it
      create(:transaction,
        gift_card: gift_card,
        merchant: merchant_b,
        amount: 3000,
        txn_type: :redemption,
        status: :succeeded,
        currency: "USD",
        processor_ref: "t1"
      )

      summary = described_class.gift_card_settlement_summary_for_redeemer(gift_card, merchant_b)

      expect(summary[:total_redeemed]).to eq(3000)
      expect(summary[:settlement_status]).to eq('pending')
      expect(summary[:issuing_merchant]).to eq(merchant_a) # Includes issuer info
    end

    it "only counts transactions performed by the specified redeemer" do
      gift_card = create(:gift_card, merchant: merchant_a, amount: 10000)

      # Merchant B redeems $30
      create(:transaction, gift_card: gift_card, merchant: merchant_b, amount: 3000, txn_type: :redemption, status: :succeeded, currency: "USD", processor_ref: "t1")

      # Merchant A (issuer) also redeems $20 (self-redemption)
      create(:transaction, gift_card: gift_card, merchant: merchant_a, amount: 2000, txn_type: :redemption, status: :succeeded, currency: "USD", processor_ref: "t2")

      # Summary for Merchant B should only show their redemption
      summary_b = described_class.gift_card_settlement_summary_for_redeemer(gift_card, merchant_b)
      expect(summary_b[:total_redeemed]).to eq(3000)

      # Summary for Merchant A should only show their redemption
      summary_a = described_class.gift_card_settlement_summary_for_redeemer(gift_card, merchant_a)
      expect(summary_a[:total_redeemed]).to eq(2000)
    end

    it "tracks settled vs pending amounts correctly" do
      gift_card = create(:gift_card, merchant: merchant_a, amount: 10000)

      # Merchant B redeems $50
      create(:transaction, gift_card: gift_card, merchant: merchant_b, amount: 5000, txn_type: :redemption, status: :succeeded, currency: "USD", processor_ref: "t1", created_at: 3.days.ago)

      # Create a settlement for Merchant B that covers this period
      create(:settlement, merchant: merchant_b, amount: 5000, period_start: 1.week.ago.to_date, period_end: Date.current, payout_status: :paid)

      summary = described_class.gift_card_settlement_summary_for_redeemer(gift_card, merchant_b)

      expect(summary[:total_redeemed]).to eq(5000)
      expect(summary[:settled_amount]).to eq(5000)
      expect(summary[:remaining_to_settle]).to eq(0)
      expect(summary[:settlement_status]).to eq('settled')
    end
  end

  describe ".calculate_pending_settlement" do
    it "sums all redemption transactions by the merchant (redeemer)" do
      gift_card_1 = create(:gift_card, merchant: merchant_a, amount: 10000)
      gift_card_2 = create(:gift_card, merchant: merchant_a, amount: 8000)

      create(:transaction, gift_card: gift_card_1, merchant: merchant_b, amount: 3000, txn_type: :redemption, status: :succeeded, currency: "USD", processor_ref: "t1")
      create(:transaction, gift_card: gift_card_2, merchant: merchant_b, amount: 4000, txn_type: :redemption, status: :succeeded, currency: "USD", processor_ref: "t2")

      pending = described_class.calculate_pending_settlement(merchant_b)

      expect(pending).to eq(7000) # $30 + $40 = $70
    end
  end
end
