require 'rails_helper'

RSpec.describe SettlementService do
  let(:merchant_a) { create(:merchant, store_name: "Merchant A (Issuer)") }
  let(:merchant_b) { create(:merchant, store_name: "Merchant B (Redeemer)") }
  let(:sender) { create(:user) }
  let(:recipient) { create(:user) }


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

end
