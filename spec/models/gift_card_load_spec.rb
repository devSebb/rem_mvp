require "rails_helper"

RSpec.describe GiftCardLoad, type: :model do
  let(:card) { create(:gift_card, amount: 5000) }

  describe "validations" do
    it "is valid with the factory defaults" do
      expect(build(:gift_card_load, gift_card: card)).to be_valid
    end

    it "requires amount_cents in 1..MAX_LOAD_CENTS" do
      expect(build(:gift_card_load, gift_card: card, amount_cents: 0)).not_to be_valid
      expect(build(:gift_card_load, gift_card: card, amount_cents: GiftCardLoad::MAX_LOAD_CENTS + 1)).not_to be_valid
      expect(build(:gift_card_load, gift_card: card, amount_cents: GiftCardLoad::MAX_LOAD_CENTS)).to be_valid
    end

    it "keeps remaining_cents within 0..amount_cents" do
      expect(build(:gift_card_load, gift_card: card, amount_cents: 1000, remaining_cents: 1001)).not_to be_valid
      expect(build(:gift_card_load, gift_card: card, amount_cents: 1000, remaining_cents: -1)).not_to be_valid
      expect(build(:gift_card_load, gift_card: card, amount_cents: 1000, remaining_cents: 0)).to be_valid
    end

    it "defaults remaining_cents to amount_cents and currency to the card's" do
      load = create(:gift_card_load, gift_card: card, amount_cents: 1234, remaining_cents: nil, currency: nil)
      expect(load.remaining_cents).to eq(1234)
      expect(load.currency).to eq("USD")
    end

    it "only accepts won/lost as a dispute outcome" do
      expect(build(:gift_card_load, gift_card: card, dispute_outcome: "meh")).not_to be_valid
      expect(build(:gift_card_load, gift_card: card, dispute_outcome: "won")).to be_valid
    end

    it "rejects a duplicate payment_intent_id at model and DB level" do
      create(:gift_card_load, gift_card: card, payment_intent_id: "pi_dup")
      dup = build(:gift_card_load, gift_card: card, payment_intent_id: "pi_dup")
      expect(dup).not_to be_valid

      expect {
        dup.save!(validate: false)
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "DB CHECK constraints" do
    let(:load) { create(:gift_card_load, gift_card: card, amount_cents: 1000) }

    it "refuses remaining_cents above amount_cents" do
      expect { load.update_column(:remaining_cents, 1001) }.to raise_error(ActiveRecord::StatementInvalid, /remaining_within_amount/)
    end

    it "refuses negative remaining_cents" do
      expect { load.update_column(:remaining_cents, -1) }.to raise_error(ActiveRecord::StatementInvalid, /remaining_within_amount/)
    end

    it "refuses negative refunded_cents" do
      expect { load.update_column(:refunded_cents, -1) }.to raise_error(ActiveRecord::StatementInvalid, /non_negative/)
    end

    it "refuses negative written_off_cents" do
      expect { load.update_column(:written_off_cents, -1) }.to raise_error(ActiveRecord::StatementInvalid, /non_negative/)
    end

    it "refuses a zero-amount load" do
      expect { load.update_columns(amount_cents: 0, remaining_cents: 0) }.to raise_error(ActiveRecord::StatementInvalid, /amount_positive/)
    end
  end

  describe "counter cache" do
    it "keeps gift_cards.loads_count in step with the loads" do
      expect(card.reload.loads_count).to eq(0)
      first = create(:gift_card_load, gift_card: card)
      create(:gift_card_load, gift_card: card)
      expect(card.reload.loads_count).to eq(2)
      first.destroy!
      expect(card.reload.loads_count).to eq(1)
    end
  end

  describe "#derived_status and #sync_status!" do
    it "is available with funds, no hold, no dispute" do
      expect(create(:gift_card_load, gift_card: card).status).to eq("available")
    end

    it "is held while held_until is in the future, and becomes stale once it passes" do
      load = create(:gift_card_load, :held, gift_card: card)
      expect(load.status).to eq("held")
      expect(load).to be_held
      expect(load.hold_remaining_seconds).to be > 0

      travel_to(25.hours.from_now) do
        expect(load).not_to be_held
        expect(load.derived_status).to eq(:available)
        expect(load).not_to be_status_in_sync
        expect(load.sync_status!).to eq(:available)
        expect(load.reload.status).to eq("available")
      end
    end

    it "is disputed only while the dispute is open" do
      load = create(:gift_card_load, :disputed, gift_card: card)
      expect(load.status).to eq("disputed")
      expect(load).to be_dispute_open

      load.update!(dispute_outcome: "won")
      expect(load).not_to be_dispute_open
      expect(load.derived_status).to eq(:available)
    end

    it "prefers the money-zero statuses over hold/dispute" do
      expect(create(:gift_card_load, :exhausted, :held, gift_card: card).derived_status).to eq(:exhausted)
      expect(create(:gift_card_load, :refunded, gift_card: card).derived_status).to eq(:refunded)
      expect(create(:gift_card_load, :dispute_lost, gift_card: card).derived_status).to eq(:written_off)
    end

    it "never derives away from canceled" do
      load = create(:gift_card_load, gift_card: card, status: :canceled)
      expect(load.derived_status).to eq(:canceled)
      expect(load.sync_status!).to eq(:canceled)
    end
  end

  describe "spendability (§3.4)" do
    it "excludes held, disputed, canceled and empty loads" do
      ok = create(:gift_card_load, gift_card: card, amount_cents: 1000)
      held = create(:gift_card_load, :held, gift_card: card, amount_cents: 1000)
      disputed = create(:gift_card_load, :disputed, gift_card: card, amount_cents: 1000)
      canceled = create(:gift_card_load, gift_card: card, amount_cents: 1000, status: :canceled)
      empty = create(:gift_card_load, :exhausted, gift_card: card, amount_cents: 1000)

      expect(GiftCardLoad.spendable.where(gift_card: card)).to contain_exactly(ok)
      expect(ok.spendable_cents).to eq(1000)
      expect([held, disputed, canceled, empty].map(&:spendable_cents)).to all(eq(0))
    end

    it "orders FIFO by created_at" do
      older = create(:gift_card_load, gift_card: card, created_at: 2.days.ago)
      newer = create(:gift_card_load, gift_card: card, created_at: 1.day.ago)
      expect(card.loads.to_a).to eq([older, newer])
    end
  end

  describe "#refundable_cents (§5.7 cap)" do
    it "is the unredeemed, not-yet-refunded part" do
      load = create(:gift_card_load, gift_card: card, amount_cents: 1000, remaining_cents: 600, refunded_cents: 300)
      expect(load.refundable_cents).to eq(600)

      load.update!(remaining_cents: 800)
      expect(load.refundable_cents).to eq(700)
    end

    it "is zero while a dispute is open" do
      expect(create(:gift_card_load, :disputed, gift_card: card).refundable_cents).to eq(0)
    end
  end

  describe "#ledger_balanced? (I2)" do
    it "holds with allocations that net to the consumed amount" do
      load = create(:gift_card_load, gift_card: card, amount_cents: 5000, remaining_cents: 3000)
      create(:redemption_allocation, gift_card_load: load, amount_cents: 3000)
      create(:redemption_allocation, :credit, gift_card_load: load, amount_cents: 1000)
      expect(load.net_redeemed_cents).to eq(2000)
      expect(load).to be_ledger_balanced
    end

    it "fails when cents leave without an allocation" do
      load = create(:gift_card_load, gift_card: card, amount_cents: 5000, remaining_cents: 4000)
      expect(load).not_to be_ledger_balanced
    end
  end
end
