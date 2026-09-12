require "rails_helper"

RSpec.describe Activity::Feed do
  let(:recipient) { create(:user) }
  let(:merchant) { create(:merchant) }
  let(:card) { create(:gift_card, recipient: recipient, merchant: merchant, amount: 0) }

  it "emits hold_released once the hold ended and write_off for lost disputes, and never a zero write-off" do
    released = stripe_load!(card, 1_000, sender: create(:user), at: 3.days.ago, held_until: 1.day.ago)
    lost = stripe_load!(card, 500, sender: create(:user), at: 2.days.ago)
    card.with_lock do
      GiftCardLoad.where(id: lost.id).update_all(remaining_cents: 0, written_off_cents: 500, disputed_at: 1.day.ago, dispute_outcome: "lost")
      GiftCard.where(id: card.id).update_all(remaining_balance: 1_000)
    end
    Transaction.create!(gift_card: card, gift_card_load: lost, merchant: merchant, amount: 500, txn_type: :adjustment, status: :succeeded,
                        currency: "USD", processor_ref: "dispute_du_1", metadata: { source: "dispute_lost" })
    Transaction.create!(gift_card: card, merchant: merchant, amount: 0, txn_type: :adjustment, status: :succeeded,
                        currency: "USD", processor_ref: "dispute_du_zero", metadata: { source: "dispute_lost" })

    page = described_class.call(user: recipient)
    types = page[:events].map { |e| [e.type, e.load_id] }
    expect(types).to include(["hold_released", released.id], ["write_off", lost.id])
    expect(page[:events].count { |e| e.type == "write_off" }).to eq(1)
    expect(page[:events].find { |e| e.type == "hold_released" }.created_at).to be_within(1.second).of(released.held_until)
  end

  it "ignores a bad cursor and honours the limit bounds" do
    stripe_load!(card, 1_000, sender: create(:user))
    expect(described_class.call(user: recipient, cursor: "!!!")[:events]).to be_empty
    expect(described_class.call(user: recipient, limit: 0)[:events].size).to eq(1)
  end
end
