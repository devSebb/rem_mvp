require "rails_helper"

# §5.5 Type A reversal: credits exactly the loads the redemption debited,
# once, full amount; shortfalls become an admin_adjustment load + alert.
RSpec.describe Refunds::Issue do
  let(:merchant_user) { create(:user, role: :merchant) }
  let(:merchant) { create(:merchant, user: merchant_user) }
  let(:buyer) { create(:user) }
  let(:card) { create(:gift_card, recipient: buyer, merchant: merchant, amount: 0) }

  before do
    stripe_load!(card, 500, sender: buyer, at: 2.days.ago)
    stripe_load!(card, 3_000, sender: create(:user), at: 1.day.ago)
    allow(AdminAlertMailer).to receive(:reversal_shortfall).and_return(double(deliver_later: true))
  end

  def reverse!(redemption, key: nil)
    described_class.call(merchant: merchant, redemption_transaction_id: redemption.id, actor: merchant_user, reason: "spec", idempotency_key: key)
  end

  it "credits the debited loads and leaves the card status alone" do
    redemption = redeem_card!(card, 2_000, merchant: merchant)
    expect(card.loads.map(&:remaining_cents)).to eq([0, 1_500])

    result = reverse!(redemption)

    expect(result[:approved]).to be(true)
    expect(result[:remaining_balance_cents]).to eq(3_500)
    expect(result[:spendable_cents]).to eq(3_500)
    expect(card.reload.loads.map(&:remaining_cents)).to eq([500, 3_000])
    expect(card.status).to eq("active")
    refund = Transaction.find(result[:refund_transaction_id])
    expect(refund.reversal_of_transaction_id).to eq(redemption.id)
    expect(refund.redemption_allocations.credit.sum(:amount_cents)).to eq(2_000)
    expect(card.verify_ledger!).to be(true)
    expect(AdminAlertMailer).not_to have_received(:reversal_shortfall)
  end

  it "refuses a second reversal of the same redemption (I5)" do
    redemption = redeem_card!(card, 1_000, merchant: merchant)
    reverse!(redemption)
    expect { reverse!(redemption) }.to raise_error(described_class::ValidationError, /already refunded/)
    expect(card.reload.remaining_balance).to eq(3_500)
  end

  it "replays an idempotency key without moving money again" do
    redemption = redeem_card!(card, 1_000, merchant: merchant)
    first = reverse!(redemption, key: "k1")
    second = reverse!(redemption, key: "k1")
    expect(second[:refund_transaction_id]).to eq(first[:refund_transaction_id])
    expect(card.reload.remaining_balance).to eq(3_500)
  end

  it "only reverses succeeded redemptions belonging to this merchant" do
    other = create(:merchant)
    redemption = redeem_card!(card, 1_000, merchant: other)
    expect { reverse!(redemption) }.to raise_error(ActiveRecord::RecordNotFound)

    failed = Transaction.create!(gift_card: card, merchant: merchant, amount: 100, txn_type: :redemption, status: :failed,
                                 currency: "USD", processor_ref: "failed_1", decline_reason: "insufficient_balance")
    expect { reverse!(failed) }.to raise_error(described_class::ValidationError, /not a successful redemption/)
  end

  it "creates an adjustment load and alerts when the original load was refunded meanwhile" do
    redemption = redeem_card!(card, 500, merchant: merchant) # drains load 1
    load = card.loads.first
    # Only reachable when the load is externally inconsistent: forge a write-off
    # that happened outside the ledger so the load can hold nothing back.
    load.update_columns(written_off_cents: 500)

    result = reverse!(redemption)

    refund = Transaction.find(result[:refund_transaction_id])
    expect(refund.metadata["shortfall_cents"]).to eq(500)
    adjustment = card.reload.loads.find(&:source_admin_adjustment?)
    expect(adjustment).to have_attributes(amount_cents: 500, remaining_cents: 500, sender_id: nil)
    expect(card.remaining_balance).to eq(3_500)
    expect(card.total_loaded_cents).to eq(4_000)
    expect(AdminAlertMailer).to have_received(:reversal_shortfall).with(card.id, refund.id, 500)
    expect(adjustment).to be_ledger_balanced
    expect(card.ledger_drift.join).not_to include("I5") # the forged load is the only drift
  end
end
