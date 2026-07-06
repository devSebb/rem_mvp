require "rails_helper"
require "ostruct"

RSpec.describe Refunds::RefundOrphanedPayment do
  let(:sender) { create(:user) }
  let(:payment_intent) do
    OpenStruct.new(
      id: "pi_orphan_123",
      amount: 5_000,
      currency: "usd",
      metadata: { "sender_id" => sender.id.to_s }
    )
  end
  let(:stripe_refund) { OpenStruct.new(id: "re_orphan_123", amount: 5_000, currency: "usd") }

  before do
    allow(AdminAlertMailer).to receive(:orphaned_payment_refunded)
      .and_return(double(deliver_later: true))
  end

  it "refuses to refund when a gift card exists for the payment intent" do
    create(:gift_card, payment_intent_id: payment_intent.id)

    expect(Stripe::Refund).not_to receive(:create)
    expect {
      described_class.call(payment_intent: payment_intent, reason: "merchant_invalid")
    }.to raise_error(described_class::GiftCardExists)
  end

  it "issues a full Stripe refund with a per-PI idempotency key" do
    expect(Stripe::Refund).to receive(:create).with(
      hash_including(payment_intent: "pi_orphan_123", reason: "requested_by_customer"),
      { idempotency_key: "orphan_refund:pi_orphan_123" }
    ).and_return(stripe_refund)

    result = described_class.call(payment_intent: payment_intent, reason: "purchase_limit_exceeded")
    expect(result).to eq(stripe_refund)
  end

  it "records a gift-card-less audit transaction and alerts admin" do
    allow(Stripe::Refund).to receive(:create).and_return(stripe_refund)

    expect {
      described_class.call(payment_intent: payment_intent, reason: "merchant_inactive")
    }.to change(Transaction.refunds, :count).by(1)

    txn = Transaction.refunds.last
    expect(txn.gift_card).to be_nil
    expect(txn.user).to eq(sender)
    expect(txn.amount).to eq(5_000)
    expect(txn.processor_ref).to eq("re_orphan_123")
    expect(txn.metadata["failure_reason"]).to eq("merchant_inactive")
    expect(txn.metadata["source"]).to eq("orphaned_payment_auto_refund")
    expect(AdminAlertMailer).to have_received(:orphaned_payment_refunded)
      .with("pi_orphan_123", 5_000, "USD", "merchant_inactive", "re_orphan_123")
  end

  it "treats an already-refunded charge as success (idempotent redelivery)" do
    allow(Stripe::Refund).to receive(:create).and_raise(
      Stripe::InvalidRequestError.new("Charge has already been refunded.", nil, code: "charge_already_refunded")
    )

    expect {
      expect(described_class.call(payment_intent: payment_intent, reason: "sender_missing")).to be_nil
    }.not_to change(Transaction, :count)
    expect(AdminAlertMailer).not_to have_received(:orphaned_payment_refunded)
  end

  it "propagates other Stripe errors so the webhook retries" do
    allow(Stripe::Refund).to receive(:create).and_raise(Stripe::APIConnectionError.new("down"))

    expect {
      described_class.call(payment_intent: payment_intent, reason: "merchant_invalid")
    }.to raise_error(Stripe::APIConnectionError)
  end
end
