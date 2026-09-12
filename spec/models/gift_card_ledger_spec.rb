require "rails_helper"

# Phase 1 additions to GiftCard / User / Merchant (RELOADABLE_CARD_PLAN.md §3).
RSpec.describe GiftCard, "reloadable-card Phase 1", type: :model do
  describe "status enum" do
    it "keeps the legacy values and adds the admin freeze as status 4" do
      expect(GiftCard.statuses).to eq(
        "active" => 0, "redeemed" => 1, "expired" => 2, "canceled" => 3, "frozen_by_admin" => 4
      )
    end

    it "does not shadow Object#frozen?" do
      card = create(:gift_card, status: :frozen_by_admin, frozen_at: Time.current, frozen_reason: "fraude")
      expect(card).to be_frozen_by_admin
      expect(card.frozen?).to be(false)
    end
  end

  describe "associations" do
    it "exposes loads FIFO and allocations through them" do
      card = create(:gift_card)
      newer = create(:gift_card_load, gift_card: card, created_at: 1.hour.ago)
      older = create(:gift_card_load, gift_card: card, created_at: 2.hours.ago)
      alloc = create(:redemption_allocation, gift_card_load: older, amount_cents: 100)

      expect(card.loads).to eq([older, newer])
      expect(card.redemption_allocations).to contain_exactly(alloc)
    end

    it "links merged cards to their survivor" do
      survivor = create(:gift_card)
      absorbed = create(:gift_card, merged_into: survivor)
      expect(absorbed.merged_into).to eq(survivor)
    end

    it "lets sender_id and amount be NULL at the DB level (deprecated columns)" do
      card = create(:gift_card)
      expect { card.update_columns(sender_id: nil, amount: nil) }.not_to raise_error
    end

    it "mirrors amount into total_loaded_cents on the legacy creation path" do
      card = create(:gift_card, amount: 1000)
      expect(card.total_loaded_cents).to eq(1000)
      expect(card.remaining_balance).to eq(1000)
    end

    it "refuses a negative remaining_balance at the DB level" do
      card = create(:gift_card, amount: 1000)
      expect { card.update_column(:remaining_balance, -1) }.to raise_error(ActiveRecord::StatementInvalid, /non_negative/)
    end

    it "refuses remaining_balance above total_loaded_cents at the DB level" do
      card = create(:gift_card, amount: 1000)
      expect { card.update_columns(total_loaded_cents: 500, remaining_balance: 600) }
        .to raise_error(ActiveRecord::StatementInvalid, /total_loaded_covers_remaining/)
    end
  end

  describe "#verify_ledger!" do
    it "passes on a card whose loads and ledger agree" do
      card = create(:gift_card, amount: 5000)
      create(:gift_card_load, gift_card: card, amount_cents: 5000)
      card.update_columns(total_loaded_cents: 5000)
      expect(card.verify_ledger!).to be(true)
      expect(card).to be_ledger_balanced
    end

    it "raises with the drift lines otherwise" do
      card = create(:gift_card, amount: 5000)
      create(:gift_card_load, gift_card: card, amount_cents: 5000)
      card.update_columns(total_loaded_cents: 5000, remaining_balance: 4000)
      expect { card.verify_ledger! }.to raise_error(Ledger::Verifier::DriftError, /I1 remaining_balance 4000/)
    end
  end
end

RSpec.describe User, "dispute counters", type: :model do
  it "defaults to unblocked" do
    user = create(:user)
    expect(user.dispute_open_count).to eq(0)
    expect(user.dispute_lost_count).to eq(0)
    expect(user).not_to be_purchases_blocked
  end

  it "is blocked with an open dispute or an admin block" do
    expect(create(:user, dispute_open_count: 1)).to be_purchases_blocked
    expect(create(:user, purchases_blocked_at: Time.current)).to be_purchases_blocked
  end

  it "knows the loads it paid for" do
    buyer = create(:user)
    load = create(:gift_card_load, sender: buyer)
    expect(buyer.sent_loads).to contain_exactly(load)
  end
end

RSpec.describe Merchant, "redemption group", type: :model do
  it "is optional and links peers" do
    group = create(:redemption_group, name: "Farmaenlace")
    a = create(:merchant, redemption_group: group)
    b = create(:merchant, redemption_group: group)
    solo = create(:merchant)

    expect(group.merchants).to contain_exactly(a, b)
    expect(solo.redemption_group).to be_nil
    expect(build(:redemption_group, name: "Farmaenlace")).not_to be_valid
  end
end
