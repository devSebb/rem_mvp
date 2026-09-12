require "rails_helper"

RSpec.describe Ledger::Verifier do
  let(:merchant) { create(:merchant) }
  let(:card) { create(:gift_card, merchant: merchant, amount: 5000) }

  # A consistent card: one load, one redemption fully allocated.
  def consistent_card!
    load = create(:gift_card_load, gift_card: card, amount_cents: 5000, remaining_cents: 3000)
    txn = Transaction.create!(gift_card: card, merchant: merchant, amount: 2000, txn_type: :redemption,
                              status: :succeeded, processor_ref: "merchant_api_v1", currency: "USD")
    RedemptionAllocation.create!(ledger_transaction: txn, gift_card_load: load, amount_cents: 2000, direction: :debit)
    card.update_columns(remaining_balance: 3000, total_loaded_cents: 5000)
    [load, txn]
  end

  it "is clean on a consistent card" do
    consistent_card!
    report = described_class.card_report(card.reload)
    expect(report.drift).to be_empty
    expect(report.warnings).to be_empty
    expect(report.info.join).to include("no purchase/issuance ledger row")
  end

  it "flags a card with no loads" do
    expect(described_class.card_drift(card)).to include(a_string_matching(/no loads/))
  end

  it "flags I1 when the cached balance disagrees with the loads" do
    consistent_card!
    card.update_columns(remaining_balance: 2999)
    expect(described_class.card_drift(card.reload)).to include(a_string_matching(/I1 remaining_balance 2999 != Σ loads.remaining_cents 3000/))
  end

  it "flags total_loaded_cents and loads_count mismatches" do
    consistent_card!
    card.update_columns(total_loaded_cents: 4000, loads_count: 2)
    drift = described_class.card_drift(card.reload)
    expect(drift).to include(a_string_matching(/total_loaded_cents 4000/))
    expect(drift).to include(a_string_matching(/loads_count 2 != 1 loads/))
  end

  it "flags I2 when a load's cents leave without an allocation" do
    load, = consistent_card!
    load.update_columns(remaining_cents: 2500)
    card.update_columns(remaining_balance: 2500)
    expect(described_class.card_drift(card.reload)).to include(a_string_matching(/I2 load #{load.id}/))
  end

  it "flags I3 when the ledger and the card totals disagree" do
    load, txn = consistent_card!
    txn.update_columns(amount: 2100)
    load.redemption_allocations.sole.update_columns(amount_cents: 2100)
    load.update_columns(remaining_cents: 2900)
    card.update_columns(remaining_balance: 2900, total_loaded_cents: 5100)
    expect(described_class.card_drift(card.reload)).to include(a_string_matching(/I3 /))
  end

  it "flags I5 when a redemption is not fully allocated" do
    load, = consistent_card!
    load.redemption_allocations.sole.update_columns(amount_cents: 1500)
    load.update_columns(remaining_cents: 3500)
    card.update_columns(remaining_balance: 3500)
    drift = described_class.card_drift(card.reload)
    expect(drift).to include(a_string_matching(/I5 redemption txn .* amount 2000 but debit allocations 1500/))
  end

  it "flags an allocation whose transaction lives on another card" do
    load, = consistent_card!
    other_card = create(:gift_card, merchant: merchant)
    foreign_txn = Transaction.create!(gift_card: other_card, merchant: merchant, amount: 100, txn_type: :redemption,
                                      status: :succeeded, processor_ref: "merchant_api_other", currency: "USD")
    RedemptionAllocation.create!(ledger_transaction: foreign_txn, gift_card_load: load, amount_cents: 100, direction: :debit)
    expect(described_class.card_drift(card.reload)).to include(a_string_matching(/not on this card/))
  end

  it "flags legacy card statuses (I9)" do
    consistent_card!
    card.update_columns(status: GiftCard.statuses[:redeemed])
    expect(described_class.card_drift(card.reload)).to include(a_string_matching(/I9 status is legacy `redeemed`/))
  end

  it "flags a frozen card without frozen_at and vice versa (I9)" do
    consistent_card!
    card.update_columns(status: GiftCard.statuses[:frozen_by_admin])
    expect(described_class.card_drift(card.reload)).to include(a_string_matching(/frozen without frozen_at/))
    card.update_columns(status: GiftCard.statuses[:active], frozen_at: Time.current)
    expect(described_class.card_drift(card.reload)).to include(a_string_matching(/frozen_at set on non-frozen/))
  end

  it "flags refunded/written_off columns that disagree with linked ledger rows" do
    load, = consistent_card!
    load.update_columns(refunded_cents: 500, remaining_cents: 2500)
    card.update_columns(remaining_balance: 2500)
    drift = described_class.card_drift(card.reload)
    expect(drift).to include(a_string_matching(/Σ Stripe refund txns 0 != refunded_cents 500/))
  end

  it "flags a funded load whose purchase row disagrees with amount_cents" do
    load, = consistent_card!
    Transaction.create!(gift_card: card, gift_card_load: load, merchant: merchant, amount: 4900, txn_type: :purchase,
                        status: :succeeded, processor_ref: "pi_mismatch", currency: "USD")
    expect(described_class.card_drift(card.reload)).to include(a_string_matching(/Σ purchase\+issuance txns 4900 != amount_cents 5000/))
  end

  it "reports a stale hold status as a warning, not drift" do
    load = create(:gift_card_load, :held, gift_card: card, amount_cents: 5000)
    card.update_columns(remaining_balance: 5000, total_loaded_cents: 5000)
    travel_to(2.days.from_now) do
      report = described_class.card_report(card.reload)
      expect(report.drift).to be_empty
      expect(report.warnings).to include(a_string_matching(/load #{load.id} status `held` stale, derived `available`/))
    end
  end

  describe ".call" do
    it "aggregates over all cards and counts duplicate pairs" do
      consistent_card!
      recipient = card.recipient
      create(:gift_card, recipient: recipient, merchant: merchant) # duplicate pair, no loads

      result = described_class.call
      expect(result.cards_checked).to eq(2)
      expect(result).not_to be_ok
      expect(result.drift).to include(a_string_matching(/no loads/))
      expect(result.duplicate_pairs).to eq({ [recipient.id, merchant.id] => 2 })
    end
  end
end
