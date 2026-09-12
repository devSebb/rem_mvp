require "rails_helper"

RSpec.describe RedemptionAllocation, type: :model do
  let(:load) { create(:gift_card_load, amount_cents: 5000) }

  it "is valid with the factory defaults and links a redemption txn to a load" do
    alloc = create(:redemption_allocation, gift_card_load: load, amount_cents: 1200)
    expect(alloc).to be_debit
    expect(alloc.ledger_transaction).to be_redemption
    expect(alloc.ledger_transaction.gift_card).to eq(load.gift_card)
    expect(alloc.ledger_transaction.redemption_allocations).to contain_exactly(alloc)
    expect(load.redemption_allocations).to contain_exactly(alloc)
  end

  it "requires a positive amount at model and DB level" do
    expect(build(:redemption_allocation, gift_card_load: load, amount_cents: 0)).not_to be_valid

    alloc = create(:redemption_allocation, gift_card_load: load)
    expect { alloc.update_column(:amount_cents, 0) }.to raise_error(ActiveRecord::StatementInvalid, /amount_positive/)
  end

  it "allows one row per (transaction, load) pair" do
    alloc = create(:redemption_allocation, gift_card_load: load)
    dup = build(:redemption_allocation, gift_card_load: load, ledger_transaction: alloc.ledger_transaction)
    expect(dup).not_to be_valid
    expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "can span loads for one redemption" do
    other = create(:gift_card_load, gift_card: load.gift_card, amount_cents: 500)
    first = create(:redemption_allocation, gift_card_load: load, amount_cents: 1500)
    second = create(:redemption_allocation, gift_card_load: other, ledger_transaction: first.ledger_transaction, amount_cents: 500)
    expect(first.ledger_transaction.redemption_allocations.sum(:amount_cents)).to eq(2000)
    expect(second.ledger_transaction).to eq(first.ledger_transaction)
  end
end
