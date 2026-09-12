require "rails_helper"

# FIFO draw-down and reversal credits (§5.4, §5.5, I2, I4, I5).
RSpec.describe Loads::Allocator do
  let(:merchant) { create(:merchant) }
  let(:card) { create(:gift_card, merchant: merchant, amount: 0) }

  def load!(amount, **attrs)
    load = create(:gift_card_load, { gift_card: card, amount_cents: amount, created_at: Time.current }.merge(attrs))
    card.update_columns(remaining_balance: card.remaining_balance + amount, total_loaded_cents: card.total_loaded_cents + amount, amount: card.amount.to_i + amount)
    card.reload
    load
  end

  def redemption_txn!(amount)
    Transaction.create!(gift_card: card, merchant: merchant, amount: amount, txn_type: :redemption, status: :succeeded,
                        currency: "USD", processor_ref: "red_#{SecureRandom.hex(4)}")
  end

  def debit!(amount)
    txn = redemption_txn!(amount)
    card.with_lock { described_class.debit!(card: card, amount_cents: amount, transaction: txn) }
    txn
  end

  describe ".debit!" do
    it "takes from the oldest load first and records one allocation per load touched" do
      a = load!(500, created_at: 2.days.ago)
      b = load!(3_000, created_at: 1.day.ago)

      txn = debit!(2_000)

      expect(a.reload.remaining_cents).to eq(0)
      expect(a.status).to eq("exhausted")
      expect(b.reload.remaining_cents).to eq(1_500)
      expect(card.reload.remaining_balance).to eq(1_500)
      expect(txn.redemption_allocations.order(:id).map { |x| [x.gift_card_load_id, x.amount_cents, x.direction] })
        .to eq([[a.id, 500, "debit"], [b.id, 1_500, "debit"]])
      expect(card.verify_ledger!).to be(true)
    end

    it "fits exactly into one load without touching the next" do
      a = load!(1_000, created_at: 2.days.ago)
      b = load!(1_000, created_at: 1.day.ago)
      txn = debit!(1_000)
      expect(a.reload.remaining_cents).to eq(0)
      expect(b.reload.remaining_cents).to eq(1_000)
      expect(txn.redemption_allocations.count).to eq(1)
    end

    it "skips held and disputed loads (I4)" do
      held = load!(2_000, created_at: 3.days.ago, held_until: 1.hour.from_now)
      disputed = load!(2_000, created_at: 2.days.ago, disputed_at: 1.hour.ago)
      free = load!(1_000, created_at: 1.day.ago)

      debit!(700)

      expect(held.reload.remaining_cents).to eq(2_000)
      expect(disputed.reload.remaining_cents).to eq(2_000)
      expect(free.reload.remaining_cents).to eq(300)
      expect(card.reload.balances).to include(remaining_balance: 4_300, held_cents: 2_000, disputed_cents: 2_000, spendable_cents: 300)
    end

    it "refuses more than the spendable total" do
      load!(1_000, created_at: 2.days.ago)
      load!(2_000, created_at: 1.day.ago, held_until: 1.hour.from_now)
      txn = redemption_txn!(1_500)
      expect {
        card.with_lock { described_class.debit!(card: card, amount_cents: 1_500, transaction: txn) }
      }.to raise_error(described_class::InsufficientSpendable) { |e| expect(e.spendable_cents).to eq(1_000) }
      expect(card.reload.remaining_balance).to eq(3_000)
    end
  end

  describe ".credit_reversal!" do
    def reversal_txn!(redemption)
      Transaction.create!(gift_card: card, merchant: merchant, amount: redemption.amount, txn_type: :refund, status: :succeeded,
                          currency: "USD", processor_ref: "rev_#{SecureRandom.hex(4)}", reversal_of_transaction_id: redemption.id)
    end

    it "restores exactly the loads the redemption debited (I5)" do
      a = load!(500, created_at: 2.days.ago)
      b = load!(3_000, created_at: 1.day.ago)
      redemption = debit!(2_000)
      reversal = reversal_txn!(redemption)

      credits = card.with_lock { described_class.credit_reversal!(card: card, reversal: reversal, redemption: redemption) }

      expect(credits.map { |c| [c.load.id, c.cents, c.shortfall_load] }).to eq([[a.id, 500, nil], [b.id, 1_500, nil]])
      expect(a.reload.remaining_cents).to eq(500)
      expect(a.status).to eq("available")
      expect(b.reload.remaining_cents).to eq(3_000)
      expect(card.reload.remaining_balance).to eq(3_500)
      expect(reversal.redemption_allocations.credit.sum(:amount_cents)).to eq(2_000)
      expect(card.verify_ledger!).to be(true)
    end

    it "creates an admin_adjustment load for cents the original load can no longer hold" do
      a = load!(1_000, created_at: 2.days.ago)
      redemption = debit!(600)
      # Meanwhile the buyer got the unredeemed 400 back at Stripe.
      Transaction.create!(gift_card: card, gift_card_load: a, merchant: merchant, amount: 400, txn_type: :refund, status: :succeeded,
                          currency: "USD", processor_ref: "re_x", metadata: { stripe_refund_id: "re_x" })
      a.update!(remaining_cents: 0, refunded_cents: 400)
      card.update_columns(remaining_balance: 0)
      expect(card.verify_ledger!).to be(true)

      reversal = reversal_txn!(redemption)
      credits = card.with_lock { described_class.credit_reversal!(card: card, reversal: reversal, redemption: redemption) }

      credit = credits.sole
      expect(credit.cents).to eq(600) # cap = 1000 − 400 refunded − 0 remaining = 600
      expect(credit.shortfall_load).to be_nil
      expect(a.reload.remaining_cents).to eq(600)
      expect(card.reload.remaining_balance).to eq(600)
      expect(card.verify_ledger!).to be(true)

      # The shortfall path is only reachable when a load is externally
      # inconsistent (I2 already broken by something outside the ledger):
      # simulate a load that can hold nothing back.
      redemption2 = debit!(600)
      a.update_columns(written_off_cents: 600) # forged: money vanished outside the ledger
      reversal2 = reversal_txn!(redemption2)
      credits2 = card.with_lock { described_class.credit_reversal!(card: card, reversal: reversal2, redemption: redemption2) }

      shortfall = credits2.sole.shortfall_load
      expect(credits2.sole.cents).to eq(0)
      expect(shortfall).to be_present
      expect(shortfall).to have_attributes(source: "admin_adjustment", amount_cents: 600, remaining_cents: 600, sender_id: nil)
      expect(shortfall).to be_ledger_balanced
      expect(card.reload.remaining_balance).to eq(600)
      expect(card.total_loaded_cents).to eq(1_600)
      expect(Transaction.where(gift_card_load_id: shortfall.id, txn_type: :issuance).sum(:amount)).to eq(600)
      expect(reversal2.redemption_allocations).to be_empty
      # Only the forged load drifts; the verifier pins it to that load.
      expect(card.ledger_drift.join).to include("load #{a.id}")
      expect(card.ledger_drift.join).not_to include("I5")
    end
  end
end
