require "rails_helper"
require "ostruct"

# Type B refunds are per load (§5.7): cap = the load's unredeemed,
# not-yet-refunded part; disputed loads are refused.
RSpec.describe Refunds::IssueStripeRefund do
  let(:admin) { create(:user, role: :admin) }
  let(:merchant) { create(:merchant) }
  let(:buyer) { create(:user) }
  let(:gift_card) { create(:gift_card, merchant: merchant, amount: 0) }
  let!(:load) { stripe_load!(gift_card, 20_000, sender: buyer, payment_intent_id: "pi_test_refund") }

  def issue(amount_cents, on: load)
    described_class.call(load: on, amount_cents: amount_cents, reason: "requested by customer", actor: admin)
  end

  it "refuses to refund more than the load's remaining (unredeemed) part" do
    redeem_card!(gift_card, 18_000, merchant: merchant) # 2_000 left on the load

    expect(Stripe::Refund).not_to receive(:create)
    expect { issue(5_000) }.to raise_error(described_class::ExceedsRefundableBalance)
  end

  it "refuses any refund on a fully redeemed load" do
    redeem_card!(gift_card, 20_000, merchant: merchant)

    expect(Stripe::Refund).not_to receive(:create)
    expect { issue(100) }.to raise_error(described_class::AlreadyFullyRefunded)
  end

  it "refuses a canceled load and a load with an open dispute" do
    load.update!(status: :canceled)
    expect { issue(1_000) }.to raise_error(described_class::AlreadyFullyRefunded)

    load.update!(status: :available, disputed_at: Time.current, dispute_id: "dp_1")
    expect { issue(1_000) }.to raise_error(described_class::LoadDisputed)
  end

  it "caps at what has not been refunded yet, per load, and leaves other loads out of it" do
    other = stripe_load!(gift_card, 3_000, sender: create(:user))
    redeem_card!(gift_card, 15_000, merchant: merchant) # FIFO: all from `load`
    load.update!(refunded_cents: 2_000, remaining_cents: 3_000) # a prior Stripe refund of 2_000
    expect(load.refundable_cents).to eq(3_000)

    refund = OpenStruct.new(id: "re_ok", amount: 3_000, currency: "usd")
    expect(Stripe::Refund).to receive(:create).with(
      hash_including(payment_intent: "pi_test_refund", amount: 3_000,
                     metadata: hash_including(gift_card_id: gift_card.id.to_s, gift_card_load_id: load.id.to_s)),
      { idempotency_key: "refund:load#{load.id}:3000:#{admin.id}" }
    ).and_return(refund)

    expect(issue(3_000)).to eq(refund)
    expect { issue(3_001) }.to raise_error(described_class::ExceedsRefundableBalance)
    expect(other.reload.refundable_cents).to eq(3_000)
  end

  it "rejects non-positive amounts" do
    expect { issue(0) }.to raise_error(described_class::InvalidAmount)
  end

  it "rejects loads without a payment intent" do
    issuance = create(:gift_card_load, :issuance, gift_card: gift_card, amount_cents: 500)
    expect { issue(100, on: issuance) }.to raise_error(described_class::MissingPaymentIntent)
  end
end
