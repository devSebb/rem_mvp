require "rails_helper"
require "ostruct"

RSpec.describe Refunds::IssueStripeRefund do
  let(:admin) { create(:user, role: :admin) }
  let(:gift_card) do
    create(:gift_card, amount: 20_000, payment_intent_id: "pi_test_refund")
  end

  def issue(amount_cents)
    described_class.call(
      gift_card: gift_card,
      amount_cents: amount_cents,
      reason: "requested by customer",
      actor: admin
    )
  end

  it "refuses to refund more than the remaining (unredeemed) balance" do
    gift_card.update!(remaining_balance: 2_000) # 18_000 already redeemed

    expect(Stripe::Refund).not_to receive(:create)
    expect { issue(5_000) }.to raise_error(described_class::ExceedsRefundableBalance)
  end

  it "refuses any refund on a fully redeemed card" do
    gift_card.update!(remaining_balance: 0, status: :redeemed)

    expect(Stripe::Refund).not_to receive(:create)
    expect { issue(100) }.to raise_error(described_class::ExceedsRefundableBalance)
  end

  it "refuses refunds on canceled cards" do
    gift_card.update!(status: :canceled)

    expect { issue(1_000) }.to raise_error(described_class::AlreadyFullyRefunded)
  end

  it "allows a refund up to the remaining balance" do
    gift_card.update!(remaining_balance: 5_000)
    refund = OpenStruct.new(id: "re_ok", amount: 5_000, currency: "usd")

    expect(Stripe::Refund).to receive(:create).with(
      hash_including(payment_intent: "pi_test_refund", amount: 5_000),
      hash_including(:idempotency_key)
    ).and_return(refund)

    expect(issue(5_000)).to eq(refund)
  end

  it "rejects non-positive amounts" do
    expect { issue(0) }.to raise_error(described_class::InvalidAmount)
  end

  it "rejects cards without a payment intent" do
    gift_card.update!(payment_intent_id: nil)

    expect { issue(1_000) }.to raise_error(described_class::MissingPaymentIntent)
  end
end
