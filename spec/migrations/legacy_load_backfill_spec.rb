require "rails_helper"

# Phase 1 backfill (migration 20260912120000 → Ledger::LegacyLoadBackfill).
# Builds cards the way the legacy code left them (card-level PI/hold/dispute,
# ledger rows without gift_card_load_id, no loads) and asserts the resulting
# loads, allocations, links and counters satisfy §7.
RSpec.describe Ledger::LegacyLoadBackfill do
  let(:merchant) { create(:merchant) }
  let(:buyer) { create(:user) }
  let(:recipient) { create(:user) }

  def legacy_card(**attrs)
    create(:gift_card, { sender: buyer, recipient: recipient, merchant: merchant, checkout_session_id: nil }.merge(attrs))
  end

  def txn(card, type, amount, ref, **attrs)
    Transaction.create!({
      gift_card: card, merchant: merchant, amount: amount, txn_type: type, status: :succeeded,
      processor_ref: ref, currency: "USD", metadata: {}
    }.merge(attrs))
  end

  def run!
    described_class.call
  end

  describe "a Stripe card with redemptions, a reversal and a Radar hold" do
    let!(:card) do
      legacy_card(amount: 5000, payment_intent_id: "pi_legacy_1", note: "Feliz cumple",
                  risk_score: 70, risk_level: "elevated", held_until: 1.hour.from_now,
                  sent_via_push: true, sent_via_email: true)
    end
    let!(:purchase) { txn(card, :purchase, 5000, "pi_legacy_1", user: buyer, metadata: { fee_cents: 150 }) }
    let!(:red1) { txn(card, :redemption, 1000, "merchant_api_r1") }
    let!(:red2) { txn(card, :redemption, 1500, "merchant_api_r2") }
    let!(:reversal) { txn(card, :refund, 1500, "refund_rev1", reversal_of_transaction_id: red2.id) }
    let!(:failed) { txn(card, :redemption, 900, "merchant_api_r3", status: :failed) }

    before do
      card.update_columns(remaining_balance: 4000) # 5000 − 1000 − 1500 + 1500
    end

    it "creates exactly one load copying the card's columns" do
      expect { run! }.to change(GiftCardLoad, :count).by(1)

      load = card.loads.sole
      expect(load).to have_attributes(
        sender_id: buyer.id, source: "stripe", payment_intent_id: "pi_legacy_1",
        amount_cents: 5000, remaining_cents: 4000, refunded_cents: 0, written_off_cents: 0,
        fee_cents: 150, currency: "USD", note: "Feliz cumple", risk_score: 70, risk_level: "elevated",
        sent_via_push: true, sent_via_email: true, sent_via_sms: false, status: "held",
        dispute_outcome: nil
      )
      expect(load.held_until).to be_within(1.second).of(card.held_until)
      expect(load.created_at).to be_within(1.second).of(card.created_at)
    end

    it "writes one debit allocation per succeeded redemption and one credit per reversal" do
      run!
      load = card.loads.sole
      allocs = load.redemption_allocations.order(:id)
      expect(allocs.map { |a| [a.transaction_id, a.direction, a.amount_cents] }).to contain_exactly(
        [red1.id, "debit", 1000], [red2.id, "debit", 1500], [reversal.id, "credit", 1500]
      )
      expect(allocs.map(&:transaction_id)).not_to include(failed.id)
    end

    it "links the purchase row to the load and leaves redemptions/reversals unlinked" do
      run!
      load = card.loads.sole
      expect(purchase.reload.gift_card_load_id).to eq(load.id)
      expect([red1, red2, reversal].map { |t| t.reload.gift_card_load_id }).to all(be_nil)
    end

    it "sets the card counters and satisfies every invariant" do
      run!
      card.reload
      expect(card).to have_attributes(total_loaded_cents: 5000, loads_count: 1, status: "active")
      expect(card.last_loaded_at).to be_within(1.second).of(card.created_at)
      expect(card.verify_ledger!).to be(true)
      expect(card.loads.sole).to be_ledger_balanced
    end

    it "is idempotent" do
      run!
      loads_before = GiftCardLoad.count
      allocs_before = RedemptionAllocation.count

      expect(run!).to eq(described_class.empty_result)
      expect(GiftCardLoad.count).to eq(loads_before)
      expect(RedemptionAllocation.count).to eq(allocs_before)
    end
  end

  describe "legacy statuses" do
    it "remaps a fully redeemed card to active with an exhausted load (D3)" do
      card = legacy_card(amount: 2000, payment_intent_id: "pi_legacy_2", status: :redeemed, redeemed_at: Time.current)
      txn(card, :redemption, 2000, "merchant_api_full")
      card.update_columns(remaining_balance: 0)

      run!
      expect(card.reload.status).to eq("active")
      expect(card.loads.sole.status).to eq("exhausted")
      expect(card.verify_ledger!).to be(true)
    end

    it "remaps expired to active" do
      card = legacy_card(amount: 2000, payment_intent_id: "pi_legacy_3", status: :expired)
      run!
      expect(card.reload.status).to eq("active")
    end
  end

  describe "a non-Stripe issuance card (seed/admin)" do
    it "gets an issuance load with no sender PI and links the issuance row" do
      card = legacy_card(amount: 1000) # after_create writes the issuance txn
      issuance = card.transactions.where(txn_type: :issuance).sole

      run!
      load = card.loads.sole
      expect(load.source).to eq("issuance")
      expect(load.payment_intent_id).to be_nil
      expect(issuance.reload.gift_card_load_id).to eq(load.id)
      expect(card.reload.verify_ledger!).to be(true)
    end
  end

  describe "Type B Stripe refund (legacy card-level)" do
    it "copies refunded_cents from the refund row and links it" do
      card = legacy_card(amount: 3000, payment_intent_id: "pi_legacy_4")
      txn(card, :purchase, 3000, "pi_legacy_4", user: buyer)
      refund = txn(card, :refund, 3000, "re_legacy_1", metadata: { stripe_refund_id: "re_legacy_1", source: "stripe_webhook" })
      card.update_columns(remaining_balance: 0, status: GiftCard.statuses[:canceled])

      run!
      load = card.loads.sole
      expect(load).to have_attributes(refunded_cents: 3000, remaining_cents: 0, status: "refunded")
      expect(refund.reload.gift_card_load_id).to eq(load.id)
      expect(card.reload.status).to eq("canceled") # canceled is not remapped
      expect(card.ledger_drift).to be_empty
    end
  end

  describe "disputes (D4)" do
    it "marks an open dispute on the load and counts it on the buyer" do
      card = legacy_card(amount: 4000, payment_intent_id: "pi_legacy_5", disputed_at: 2.days.ago)
      run!

      load = card.loads.sole
      expect(load.status).to eq("disputed")
      expect(load).to be_dispute_open
      expect(load.disputed_at).to be_within(1.second).of(card.disputed_at)
      expect(buyer.reload.dispute_open_count).to eq(1)
      expect(buyer.dispute_lost_count).to eq(0)
      expect(buyer).to be_purchases_blocked
      expect(card.reload.status).to eq("active")
      expect(card.verify_ledger!).to be(true)
    end

    it "records a lost dispute as a write-off with the Stripe dispute id" do
      card = legacy_card(amount: 4000, payment_intent_id: "pi_legacy_6", disputed_at: 10.days.ago)
      txn(card, :redemption, 1000, "merchant_api_d1")
      write_off = txn(card, :adjustment, 3000, "dispute_dp_legacy_1", metadata: { stripe_dispute_id: "dp_legacy_1", source: "dispute_lost" })
      card.update_columns(remaining_balance: 0, status: GiftCard.statuses[:canceled])

      run!
      load = card.loads.sole
      expect(load).to have_attributes(written_off_cents: 3000, remaining_cents: 0, status: "written_off",
                                      dispute_outcome: "lost", dispute_id: "dp_legacy_1")
      expect(write_off.reload.gift_card_load_id).to eq(load.id)
      expect(buyer.reload.dispute_lost_count).to eq(1)
      expect(buyer.dispute_open_count).to eq(0)
      expect(card.reload.ledger_drift).to be_empty
    end
  end

  describe "a test card zeroed by gift_cards:cancel_fakes (no ledger row)" do
    it "copies the numbers verbatim and the verifier reports a warning, not drift" do
      card = legacy_card(amount: 2500, payment_intent_id: "pi_legacy_7")
      card.update_columns(remaining_balance: 0, status: GiftCard.statuses[:canceled])

      run!
      report = Ledger::Verifier.card_report(card.reload)
      expect(report.drift).to be_empty
      expect(report.warnings.join).to include("legacy canceled card")
      expect(card.loads.sole.status).to eq("exhausted")
    end
  end

  describe "Phase 2 merge shells" do
    it "never creates a load for an absorbed card" do
      survivor = legacy_card(amount: 1000, payment_intent_id: "pi_legacy_9")
      shell = create(:gift_card, recipient: recipient, merchant: merchant, merged_into: survivor, checkout_session_id: nil)
      shell.update_columns(status: GiftCard.statuses[:canceled], remaining_balance: 0, total_loaded_cents: 0)
      shell.transactions.destroy_all

      result = run!
      expect(result[:cards]).to eq(1)
      expect(shell.loads.count).to eq(0)
      expect(Ledger::Verifier.card_drift(shell.reload)).to be_empty
    end
  end

  describe "cards created after the migration" do
    it "only touches cards that have no loads yet" do
      untouched = create(:gift_card)
      existing = create(:gift_card_load, gift_card: untouched, amount_cents: 700)
      legacy = legacy_card(amount: 1000, payment_intent_id: "pi_legacy_8")

      result = run!
      expect(result[:cards]).to eq(1)
      expect(untouched.loads.reload).to contain_exactly(existing)
      expect(legacy.loads.count).to eq(1)
    end
  end
end
