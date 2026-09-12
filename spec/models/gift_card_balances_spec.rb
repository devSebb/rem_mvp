require "rails_helper"

# Phase 3a model surface: GiftCard#balances (§3.4), find_or_create_for!
# (§5.2, §6.3), the legacy issuance bridge, and the §8.1 serializer compat.
RSpec.describe GiftCard, "balances and creation", type: :model do
  let(:merchant) { create(:merchant) }
  let(:recipient) { create(:user) }
  let(:buyer) { create(:user) }

  describe "#balances" do
    let(:card) { create(:gift_card, recipient: recipient, merchant: merchant, amount: 0) }

    it "splits remaining into spendable / held / disputed and reports the earliest hold" do
      stripe_load!(card, 1_000, sender: buyer, at: 3.days.ago)
      soon = 1.hour.from_now
      stripe_load!(card, 2_000, sender: buyer, at: 2.days.ago, held_until: 3.hours.from_now)
      stripe_load!(card, 3_000, sender: buyer, at: 1.day.ago, held_until: soon)
      stripe_load!(card, 4_000, sender: buyer, disputed_at: Time.current, dispute_id: "dp_1")
      create(:gift_card_load, gift_card: card, amount_cents: 700, status: :canceled) # out of scope

      b = card.reload.balances
      expect(b).to include(remaining_balance: 10_000, held_cents: 5_000, disputed_cents: 4_000, spendable_cents: 1_000)
      expect(b[:held_until]).to be_within(1.second).of(soon)
      expect(card).to be_held
      expect(card).to be_disputed
      expect(card.hold_remaining_seconds).to be_between(3_500, 3_600)
      expect(GiftCard.currently_held).to include(card)
      expect(GiftCard.disputed).to include(card)
    end

    it "treats a load with a closed (won) dispute as spendable again and an expired hold as free" do
      stripe_load!(card, 1_000, sender: buyer, held_until: 1.hour.ago)
      stripe_load!(card, 2_000, sender: buyer, disputed_at: 2.days.ago, dispute_outcome: "won")
      expect(card.reload.balances).to include(spendable_cents: 3_000, held_cents: 0, disputed_cents: 0, held_until: nil)
      expect(card).not_to be_held
      expect(card).not_to be_disputed
    end

    it "is never spendable on a frozen or canceled card, while remaining is still reported" do
      stripe_load!(card, 1_000, sender: buyer)
      card.update_columns(status: GiftCard.statuses[:frozen_by_admin], frozen_at: Time.current)
      expect(card.reload.balances).to include(remaining_balance: 1_000, spendable_cents: 0)
      card.update_columns(status: GiftCard.statuses[:canceled])
      expect(card.reload.spendable_cents).to eq(0)
    end

    it "sums refundable_to_buyer_cents over loads" do
      stripe_load!(card, 1_000, sender: buyer)
      stripe_load!(card, 2_000, sender: buyer)
      redeem_card!(card, 1_500, merchant: merchant)
      expect(card.reload.refundable_to_buyer_cents).to eq(1_500)
    end
  end

  describe ".find_or_create_for!" do
    it "creates an empty card once per (recipient, merchant) with a REM code and the first sender" do
      card = GiftCard.find_or_create_for!(recipient: recipient, merchant: merchant, first_sender: buyer)
      expect(card).to have_attributes(remaining_balance: 0, total_loaded_cents: 0, amount: 0, loads_count: 0, sender_id: buyer.id, status: "active")
      expect(card.raw_code).to be_present
      expect(card.transactions).to be_empty

      again = GiftCard.find_or_create_for!(recipient: recipient, merchant: merchant, first_sender: create(:user))
      expect(again).to eq(card)
      expect(again.sender_id).to eq(buyer.id)
    end

    it "returns a canceled card for the pair (the caller refuses the load) and never a merge shell" do
      card = create(:gift_card, recipient: recipient, merchant: merchant, status: :canceled, amount: 0)
      expect(GiftCard.find_or_create_for!(recipient: recipient, merchant: merchant)).to eq(card)

      shell = create(:gift_card, recipient: recipient, merchant: create(:merchant), amount: 0)
      survivor = create(:gift_card, recipient: recipient, merchant: create(:merchant), amount: 0)
      shell.update_columns(merged_into_id: survivor.id, merchant_id: survivor.merchant_id, status: GiftCard.statuses[:canceled])
      expect(GiftCard.find_or_create_for!(recipient: recipient, merchant: survivor.merchant)).to eq(survivor)
    end

    it "wins the insert race by finding the concurrently created card" do
      existing = create(:gift_card, recipient: recipient, merchant: merchant, amount: 0)
      allow(GiftCard).to receive(:not_merged).and_wrap_original do |m, *args|
        rel = m.call(*args)
        allow(rel).to receive(:find_by).and_return(nil, existing)
        rel
      end
      expect(GiftCard.find_or_create_for!(recipient: recipient, merchant: merchant)).to eq(existing)
    end
  end

  describe "legacy issuance bridge" do
    it "turns a card created with a face value into one issuance load linked to the issuance row" do
      card = create(:gift_card, recipient: recipient, merchant: merchant, sender: buyer, amount: 2_500, checkout_session_id: nil)
      load = card.loads.sole
      expect(load).to have_attributes(source: "issuance", amount_cents: 2_500, remaining_cents: 2_500, sender_id: buyer.id)
      expect(card.transactions.where(txn_type: :issuance).sole.gift_card_load_id).to eq(load.id)
      expect(card).to have_attributes(remaining_balance: 2_500, total_loaded_cents: 2_500, loads_count: 1)
      expect(card.verify_ledger!).to be(true)
    end

    it "copies a legacy hold onto the bridge load" do
      card = create(:gift_card, recipient: recipient, merchant: merchant, amount: 1_000, held_until: 1.hour.from_now)
      expect(card.loads.sole).to be_held
      expect(card).to be_held
    end

    it "stays quiet for an empty card" do
      card = create(:gift_card, recipient: recipient, merchant: merchant, amount: 0)
      expect(card.loads).to be_empty
    end
  end

  describe GiftCardSerializer do
    it "keeps the old-app compat fields and adds the per-load breakdown (§8.1)" do
      card = create(:gift_card, recipient: recipient, merchant: merchant, amount: 0)
      first = stripe_load!(card, 1_000, sender: buyer, at: 2.days.ago, note: "primera")
      latest = stripe_load!(card, 2_000, sender: recipient, at: 1.day.ago, note: "recarga propia", held_until: 1.hour.from_now)

      json = described_class.call(card.reload, attachment_url: ->(_a) { nil })

      expect(json).to include(
        id: card.id, amount_cents: 3_000, remaining_balance_cents: 3_000, spendable_cents: 1_000, held_cents: 2_000,
        disputed_cents: 0, total_loaded_cents: 3_000, loads_count: 2, status: "active", sender_id: recipient.id,
        note: "recarga propia", recipient_id: recipient.id, merchant_id: merchant.id, store_name: merchant.store_name
      )
      expect(json[:held_until]).to eq(latest.held_until.iso8601)
      expect(json[:sender]).to include(id: recipient.id)
      expect(json[:loads].map { |l| l[:id] }).to eq([latest.id, first.id])
      expect(json[:loads].first).to include(amount_cents: 2_000, status: "held", is_self: true)
      expect(json[:loads].last).to include(amount_cents: 1_000, status: "available", is_self: false, note: "primera")
    end

    it "exposes a frozen card as \"frozen\" and legacy statuses as active" do
      card = create(:gift_card, recipient: recipient, merchant: merchant, amount: 0)
      card.update_columns(status: GiftCard.statuses[:frozen_by_admin], frozen_at: Time.current, frozen_reason: "fraude")
      json = described_class.call(card.reload, attachment_url: ->(_a) { nil })
      expect(json).to include(status: "frozen", frozen_reason: "fraude", spendable_cents: 0)

      card.update_columns(status: GiftCard.statuses[:redeemed])
      expect(described_class.call(card.reload, attachment_url: ->(_a) { nil })[:status]).to eq("active")
    end
  end
end
