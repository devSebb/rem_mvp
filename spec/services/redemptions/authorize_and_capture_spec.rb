require "rails_helper"

# §5.4: declines in order, FIFO capture with allocations, idempotent replay
# (declines included), token used only on success.
RSpec.describe Redemptions::AuthorizeAndCapture do
  let(:group) { create(:redemption_group, name: "Farmaenlace") }
  let(:issuer) { create(:merchant, redemption_group: group) }
  let(:peer) { create(:merchant, redemption_group: group) }
  let(:outsider) { create(:merchant) }
  let(:recipient) { create(:user) }
  let(:buyer) { create(:user) }
  let(:card) { create(:gift_card, recipient: recipient, merchant: issuer, amount: 0) }

  def token!(for_card = card, expires_at: 5.minutes.from_now)
    raw = SecureRandom.base58(10).upcase
    for_card.redemption_tokens.create!(token_digest: RedemptionToken.digest(raw), expires_at: expires_at)
    raw
  end

  def redeem(amount, merchant: issuer, token: token!, key: SecureRandom.uuid)
    described_class.call(merchant: merchant, raw_token: token, amount_cents: amount, idempotency_key: key)
  end

  before do
    stripe_load!(card, 500, sender: buyer, at: 2.days.ago)
    stripe_load!(card, 3_000, sender: create(:user), at: 1.day.ago)
  end

  it "captures FIFO across loads, marks the token used and reports spendable + total" do
    raw = token!
    result = redeem(2_000, token: raw)

    expect(result[:approved]).to be(true)
    expect(result).to include(remaining_balance_cents: 1_500, spendable_cents: 1_500, total_balance_cents: 1_500, amount_cents: 2_000)
    expect(card.reload.remaining_balance).to eq(1_500)
    expect(card.loads.map(&:remaining_cents)).to eq([0, 1_500])
    expect(card.status).to eq("active")
    txn = result[:transaction]
    expect(txn.redemption_allocations.map { |a| [a.gift_card_load_id, a.amount_cents] }).to eq(card.loads.map { |l| [l.id, l.id == card.loads.first.id ? 500 : 1_500] })
    expect(RedemptionToken.find_by(token_digest: RedemptionToken.digest(raw)).used_at).to be_present
    expect(card.verify_ledger!).to be(true)
  end

  it "never flips the card to redeemed when the balance hits zero (D3)" do
    redeem(3_500)
    expect(card.reload.status).to eq("active")
    expect(card.remaining_balance).to eq(0)
  end

  it "declines merchant_mismatch for a merchant outside the issuer's group, approves a peer (D6)" do
    result = redeem(100, merchant: outsider)
    expect(result[:approved]).to be(false)
    expect(result[:decline_reason]).to eq("merchant_mismatch")
    expect(card.reload.remaining_balance).to eq(3_500)

    result = redeem(100, merchant: peer)
    expect(result[:approved]).to be(true)
    expect(result[:transaction].merchant_id).to eq(peer.id)
  end

  it "declines insufficient_balance with held/disputed breakdown when the amount exceeds spendable" do
    card.loads.last.update!(held_until: 1.hour.from_now)
    result = redeem(600)
    expect(result[:decline_reason]).to eq("insufficient_balance")
    expect(result).to include(spendable_cents: 500, held_cents: 3_000, disputed_cents: 0, total_balance_cents: 3_500)
  end

  it "declines card_held_security_review with the earliest hold when only held funds remain" do
    card.loads.first.update!(remaining_cents: 0)
    card.update_columns(remaining_balance: 3_000)
    hold_until = 2.hours.from_now
    card.loads.last.update!(held_until: hold_until)

    result = redeem(100)
    expect(result[:decline_reason]).to eq("card_held_security_review")
    expect(result[:held_until]).to eq(hold_until.iso8601)
  end

  it "declines card_disputed only when nothing else is spendable" do
    card.loads.last.update!(disputed_at: Time.current, dispute_id: "dp_1")
    expect(redeem(500)[:approved]).to be(true) # the clean load still spends

    result = redeem(100)
    expect(result[:decline_reason]).to eq("card_disputed")
    expect(result[:disputed_cents]).to eq(3_000)
  end

  it "declines card_frozen for an admin-frozen card and gift_card_inactive for a canceled one" do
    card.update_columns(status: GiftCard.statuses[:frozen_by_admin], frozen_at: Time.current)
    expect(redeem(100)[:decline_reason]).to eq("card_frozen")

    card.update_columns(status: GiftCard.statuses[:canceled], frozen_at: nil)
    expect(redeem(100)[:decline_reason]).to eq("gift_card_inactive")
  end

  it "declines invalid, expired and used tokens" do
    expect(redeem(100, token: "NOPE")[:decline_reason]).to eq("invalid_token")
    expect(redeem(100, token: token!(expires_at: 1.second.ago))[:decline_reason]).to eq("expired_token")
    raw = token!
    redeem(100, token: raw)
    expect(redeem(100, token: raw)[:decline_reason]).to eq("token_used")
  end

  it "replays the same (merchant, idempotency_key) verbatim, declines included, without moving money twice" do
    key = SecureRandom.uuid
    first = redeem(1_000, key: key)
    second = redeem(1_000, key: key, token: "IGNORED")
    expect(second[:transaction_id]).to eq(first[:transaction_id])
    expect(card.reload.remaining_balance).to eq(2_500)

    dkey = SecureRandom.uuid
    declined = redeem(100, merchant: outsider, key: dkey)
    replay = redeem(100, merchant: outsider, key: dkey)
    expect(replay[:transaction_id]).to eq(declined[:transaction_id])
    expect(replay[:decline_reason]).to eq("merchant_mismatch")
  end

  it "validates the request" do
    expect { redeem(0) }.to raise_error(described_class::ValidationError)
    expect { described_class.call(merchant: issuer, raw_token: token!, amount_cents: 100, idempotency_key: nil) }.to raise_error(described_class::ValidationError)
  end
end
