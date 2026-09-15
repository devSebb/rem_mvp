require "rails_helper"

# Phase 2 merge (RELOADABLE_CARD_PLAN.md §10 Phase 2 step 2–3, §12.1 migration
# spec): three cards on the same (recipient, merchant) pair, with tokens and
# ledger rows, fold into the oldest card. Asserts balances, FK re-pointing,
# audit rows, idempotency, the DRY_RUN contract and I10 (settlement totals
# unchanged).
RSpec.describe GiftCards::MergeDuplicates do
  # The fixtures below are the pre-Phase-2 shape (several cards per pair),
  # which the Phase 2 unique index forbids. Drop it inside the example's
  # transaction (PostgreSQL DDL is transactional, so it is back afterwards).
  before do
    conn = ActiveRecord::Base.connection
    pair_index = "index_gift_cards_on_recipient_merchant_unique"
    conn.remove_index(:gift_cards, name: pair_index) if conn.index_exists?(:gift_cards, [:recipient_id, :merchant_id], name: pair_index)
  end

  let(:io) { StringIO.new }
  let(:issuer) { create(:merchant, store_name: "Farmacia Norte") }
  let(:redeemer) { create(:merchant, store_name: "Farmaenlace POS") }
  let(:recipient) { create(:user) }
  let(:buyer_a) { create(:user) }
  let(:buyer_b) { create(:user) }

  # Legacy-shaped card: one load, counters consistent, optional redemption
  # by `redeemer` with its allocation. Mirrors what the Phase 1 backfill
  # leaves behind.
  def legacy_card(created_at:, amount:, sender:, redeemed: 0, status: :active, pi: nil)
    card = create(:gift_card, recipient: recipient, merchant: issuer, sender: sender, amount: amount,
                  created_at: created_at, status: status, checkout_session_id: nil, payment_intent_id: pi)
    card.transactions.destroy_all # drop the legacy issuance row; we write our own below
    load = create(:gift_card_load, gift_card: card, sender: sender, amount_cents: amount,
                  remaining_cents: amount - redeemed, payment_intent_id: pi, created_at: created_at)
    Transaction.create!(gift_card: card, gift_card_load: load, merchant: issuer, user: sender, amount: amount,
                        txn_type: :issuance, status: :succeeded, currency: "USD", processor_ref: "iss_#{card.id}")
    if redeemed.positive?
      txn = Transaction.create!(gift_card: card, merchant: redeemer, amount: redeemed, txn_type: :redemption,
                                status: :succeeded, currency: "USD", processor_ref: "red_#{card.id}")
      RedemptionAllocation.create!(ledger_transaction: txn, gift_card_load: load, amount_cents: redeemed, direction: :debit)
    end
    card.update_columns(remaining_balance: amount - redeemed, total_loaded_cents: amount, last_loaded_at: created_at)
    RedemptionToken.create!(gift_card: card, token_digest: "tok_#{card.id}", expires_at: 1.minute.from_now)
    card.reload
  end

  def unsettled_snapshot
    Merchant.order(:id).map { |m| [m.id, m.unsettled_net_redeemed_cents] }
  end

  describe "three cards on one pair" do
    let!(:oldest) { legacy_card(created_at: 3.days.ago, amount: 5000, sender: buyer_a, redeemed: 2000) }
    let!(:middle) { legacy_card(created_at: 2.days.ago, amount: 3000, sender: buyer_b) }
    let!(:newest) { legacy_card(created_at: 1.day.ago, amount: 1000, sender: buyer_a, redeemed: 1000) }
    let!(:unrelated) { create(:gift_card, recipient: recipient, merchant: redeemer) }

    it "DRY_RUN lists the group with the survivor and projected result and changes nothing" do
      before = [GiftCard.pluck(:id, :status, :remaining_balance, :merged_into_id),
                GiftCardLoad.pluck(:id, :gift_card_id), Transaction.pluck(:id, :gift_card_id),
                RedemptionToken.pluck(:id, :gift_card_id)]

      result = described_class.call(dry_run: true, io: io)

      expect(result.groups.size).to eq(1)
      group = result.groups.first
      expect(group.survivor).to eq(oldest)
      expect(group).not_to be_skipped
      expect(group.result).to include(remaining_balance: 6000, total_loaded_cents: 9000, loads_count: 3,
                                      transactions: 5, redemption_tokens: 3)
      expect(io.string).to include("DRY RUN", "SURVIVOR", "absorb", "recipient #{recipient.id} × merchant #{issuer.id}")
      expect([GiftCard.pluck(:id, :status, :remaining_balance, :merged_into_id),
              GiftCardLoad.pluck(:id, :gift_card_id), Transaction.pluck(:id, :gift_card_id),
              RedemptionToken.pluck(:id, :gift_card_id)]).to eq(before)
    end

    it "merges into the oldest card, re-points every FK, and keeps absorbed rows for audit" do
      snapshot = unsettled_snapshot

      result = described_class.call(dry_run: false, io: io)
      expect(result.merged.size).to eq(1)
      expect(result.skipped).to be_empty

      oldest.reload
      expect(oldest).to have_attributes(status: "active", remaining_balance: 6000, total_loaded_cents: 9000,
                                        amount: 9000, loads_count: 3, merged_into_id: nil)
      expect(oldest.last_loaded_at).to be_within(1.second).of(newest.created_at)
      expect(oldest.loads.map(&:amount_cents)).to eq([5000, 3000, 1000]) # FIFO order preserved
      expect(oldest.loads.map(&:remaining_cents)).to eq([3000, 3000, 0])
      expect(Transaction.where(gift_card_id: oldest.id).count).to eq(5)
      expect(RedemptionToken.where(gift_card_id: oldest.id).count).to eq(3)

      [middle, newest].each do |absorbed|
        absorbed.reload
        expect(absorbed).to have_attributes(status: "canceled", merged_into_id: oldest.id,
                                            remaining_balance: 0, total_loaded_cents: 0, loads_count: 0)
        expect(GiftCardLoad.where(gift_card_id: absorbed.id)).to be_empty
        expect(Transaction.where(gift_card_id: absorbed.id)).to be_empty
        expect(RedemptionToken.where(gift_card_id: absorbed.id)).to be_empty
      end
      expect(GiftCard.exists?(middle.id)).to be(true)
      expect(GiftCard.exists?(newest.id)).to be(true)
      expect(unrelated.reload.merged_into_id).to be_nil

      # I1–I5 on the survivor; I10 across merchants.
      expect(oldest.verify_ledger!).to be(true)
      expect(unsettled_snapshot).to eq(snapshot)
      expect(Transaction.net_redeemed_cents(merchant_id: redeemer.id)).to eq(3000)
    end

    it "is idempotent" do
      described_class.call(dry_run: false, io: io)
      result = described_class.call(dry_run: false, io: StringIO.new)
      expect(result.groups).to be_empty
      expect(GiftCard.where(merged_into_id: nil).group(:recipient_id, :merchant_id).having("count(*) > 1").count).to be_empty
    end

    it "carries a disputed or held load over unchanged and propagates the legacy card guards" do
      middle.loads.sole.update!(disputed_at: 1.hour.ago)
      middle.update_columns(disputed_at: 1.hour.ago)
      newest.loads.sole.update!(held_until: 2.hours.from_now) # exhausted, but the guard still propagates
      newest.update_columns(held_until: 2.hours.from_now)

      described_class.call(dry_run: false, io: io)
      oldest.reload
      expect(oldest.status).to eq("active")
      expect(oldest.loads.map(&:status)).to eq(%w[available disputed exhausted])
      expect(oldest.disputed_at).to be_within(1.second).of(middle.disputed_at)
      expect(oldest.held_until).to be_within(1.second).of(newest.held_until)
      expect(oldest.verify_ledger!).to be(true)
    end
  end

  describe "canceled cards in the pair" do
    it "absorbs a dispute-lost (fully voided) canceled card, keeping its write-off history" do
      survivor = legacy_card(created_at: 2.days.ago, amount: 4000, sender: buyer_a)
      lost = legacy_card(created_at: 3.days.ago, amount: 2000, sender: buyer_b, status: :canceled)
      lost_load = lost.loads.sole
      write_off = Transaction.create!(gift_card: lost, gift_card_load: lost_load, merchant: issuer, amount: 2000,
                                      txn_type: :adjustment, status: :succeeded, currency: "USD",
                                      processor_ref: "dispute_dp_1", metadata: { stripe_dispute_id: "dp_1" })
      lost_load.update!(remaining_cents: 0, written_off_cents: 2000, disputed_at: 4.days.ago, dispute_outcome: "lost")
      lost.update_columns(remaining_balance: 0)

      result = described_class.call(dry_run: false, io: io)
      expect(result.groups.first.survivor).to eq(survivor) # oldest NON-canceled wins
      survivor.reload
      expect(survivor).to have_attributes(remaining_balance: 4000, total_loaded_cents: 6000, loads_count: 2, status: "active")
      expect(write_off.reload.gift_card_id).to eq(survivor.id)
      expect(lost.reload).to have_attributes(status: "canceled", merged_into_id: survivor.id)
      expect(survivor.verify_ledger!).to be(true)
      expect(buyer_b.reload.dispute_lost_count).to eq(0) # counters are Phase 3's job; merge never touches users
    end

    it "skips a group whose canceled card still carries a balance, and says why" do
      legacy_card(created_at: 2.days.ago, amount: 4000, sender: buyer_a)
      voided = legacy_card(created_at: 1.day.ago, amount: 2000, sender: buyer_b, status: :canceled)
      expect(voided.remaining_balance).to eq(2000)

      result = described_class.call(dry_run: false, io: io)
      expect(result.skipped.size).to eq(1)
      expect(result.skipped.first.skipped_reason).to include("canceled card(s) [#{voided.id}] still carry a balance")
      expect(io.string).to include("SKIPPED")
      expect(voided.reload.merged_into_id).to be_nil
      expect(GiftCard.where(merged_into_id: nil, recipient_id: recipient.id, merchant_id: issuer.id).count).to eq(2)
    end

    it "picks the oldest card when every card in the pair is canceled" do
      a = legacy_card(created_at: 3.days.ago, amount: 1000, sender: buyer_a, status: :canceled)
      b = legacy_card(created_at: 2.days.ago, amount: 1000, sender: buyer_b, status: :canceled)
      [a, b].each do |c| # fully refunded at Stripe, with the ledger row that proves it
        load = c.loads.sole
        Transaction.create!(gift_card: c, gift_card_load: load, merchant: issuer, amount: 1000, txn_type: :refund,
                            status: :succeeded, currency: "USD", processor_ref: "re_#{c.id}", metadata: { stripe_refund_id: "re_#{c.id}" })
        load.update!(remaining_cents: 0, refunded_cents: 1000)
        c.update_columns(remaining_balance: 0)
      end

      result = described_class.call(dry_run: false, io: io)
      expect(result.groups.first.survivor).to eq(a)
      expect(a.reload).to have_attributes(status: "canceled", merged_into_id: nil, loads_count: 2)
      expect(b.reload.merged_into_id).to eq(a.id)
    end
  end

  describe "guards" do
    it "skips a group with a card that has no loads" do
      legacy_card(created_at: 2.days.ago, amount: 4000, sender: buyer_a)
      create(:gift_card, recipient: recipient, merchant: issuer, created_at: 1.day.ago) # Phase 1 factory: no load

      result = described_class.call(dry_run: false, io: io)
      expect(result.skipped.first.skipped_reason).to include("backfill_missing_loads")
    end

    it "skips a group containing an admin-frozen card" do
      legacy_card(created_at: 2.days.ago, amount: 4000, sender: buyer_a)
      legacy_card(created_at: 1.day.ago, amount: 1000, sender: buyer_b, status: :frozen_by_admin)

      result = described_class.call(dry_run: false, io: io)
      expect(result.skipped.first.skipped_reason).to include("frozen")
    end

    it "rolls the group back if the survivor would drift" do
      legacy_card(created_at: 2.days.ago, amount: 4000, sender: buyer_a)
      bad = legacy_card(created_at: 1.day.ago, amount: 1000, sender: buyer_b)
      bad.loads.sole.update_columns(remaining_cents: 400) # money left without an allocation

      expect { described_class.call(dry_run: false, io: io) }.to raise_error(GiftCards::MergeDuplicates::DriftAfterMerge, /I2/)
      expect(bad.reload.merged_into_id).to be_nil
      expect(bad.loads.count).to eq(1)
    end
  end
end
