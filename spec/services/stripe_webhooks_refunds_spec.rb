require "rails_helper"
require "ostruct"

# Refund/dispute reconciliation: the paths that keep the internal ledger in
# sync with money movements that happen at Stripe (dashboard refunds, admin
# refunds, failed refunds, lost chargebacks, declined payments).
RSpec.describe StripeWebhooks do
  let(:gift_card) do
    create(:gift_card, amount: 5000, payment_intent_id: "pi_refund_test_#{SecureRandom.hex(4)}")
  end

  def build_refund(overrides = {})
    OpenStruct.new(
      {
        id: "re_test_#{SecureRandom.hex(4)}",
        amount: 5000,
        currency: "usd",
        status: "succeeded",
        payment_intent: gift_card.payment_intent_id,
        charge: "ch_test_#{SecureRandom.hex(4)}",
        reason: "requested_by_customer",
        failure_reason: nil
      }.merge(overrides)
    )
  end

  before do
    allow(AdminAlertMailer).to receive(:refund_failed).and_return(double(deliver_later: true))
    allow(AdminAlertMailer).to receive(:payment_failed).and_return(double(deliver_later: true))
    allow(AdminAlertMailer).to receive(:dispute_closed).and_return(double(deliver_later: true))
  end

  describe ".handle_refund_event" do
    context "full refund (succeeded)" do
      it "cancels the card, zeroes the balance, and records a ledger row" do
        refund = build_refund

        described_class.handle_refund_event(refund)

        gift_card.reload
        expect(gift_card.status).to eq("canceled")
        expect(gift_card.remaining_balance).to eq(0)

        txn = Transaction.refunds.find_by(processor_ref: refund.id)
        expect(txn).to be_present
        expect(txn.status).to eq("succeeded")
        expect(txn.amount).to eq(5000)
        expect(txn.metadata["stripe_refund_id"]).to eq(refund.id)
        expect(txn.metadata["previous_card_status"]).to eq("active")
        expect(txn.metadata["source"]).to eq("stripe_webhook")
      end
    end

    context "partial refund" do
      it "reduces the balance and keeps the card active" do
        refund = build_refund(amount: 2000)

        described_class.handle_refund_event(refund)

        gift_card.reload
        expect(gift_card.status).to eq("active")
        expect(gift_card.remaining_balance).to eq(3000)
      end
    end

    context "re-delivery / overlapping events (refund.created then refund.updated)" do
      it "records the refund exactly once" do
        refund = build_refund

        described_class.handle_refund_event(refund)
        described_class.handle_refund_event(refund)

        expect(Transaction.refunds.where("metadata->>'stripe_refund_id' = ?", refund.id).count).to eq(1)
        expect(gift_card.reload.remaining_balance).to eq(0)
      end
    end

    context "pending refund" do
      it "debits immediately (refund.failed reverses later if needed)" do
        refund = build_refund(status: "pending")

        described_class.handle_refund_event(refund)

        expect(gift_card.reload.status).to eq("canceled")
      end
    end

    context "refund fails after being applied" do
      it "restores balance and status, marks the ledger row failed, and alerts admin" do
        refund = build_refund
        described_class.handle_refund_event(refund)
        expect(gift_card.reload.status).to eq("canceled")

        failed = build_refund(id: refund.id, status: "failed", failure_reason: "unknown")
        described_class.handle_refund_event(failed)

        gift_card.reload
        expect(gift_card.status).to eq("active")
        expect(gift_card.remaining_balance).to eq(5000)

        txn = Transaction.find_by(processor_ref: refund.id)
        expect(txn.status).to eq("failed")
        expect(txn.metadata["refund_failure_reason"]).to eq("unknown")
        expect(AdminAlertMailer).to have_received(:refund_failed).with(gift_card.id, refund.id, 5000, "USD", "unknown")
      end

      it "is idempotent — a second failed delivery does not double-restore" do
        refund = build_refund
        described_class.handle_refund_event(refund)
        failed = build_refund(id: refund.id, status: "failed")

        described_class.handle_refund_event(failed)
        described_class.handle_refund_event(failed)

        expect(gift_card.reload.remaining_balance).to eq(5000)
        expect(AdminAlertMailer).to have_received(:refund_failed).once
      end
    end

    context "failed refund that was never applied" do
      it "does nothing" do
        failed = build_refund(status: "failed")

        expect { described_class.handle_refund_event(failed) }
          .not_to change { gift_card.reload.remaining_balance }
      end
    end

    context "no gift card for the payment intent (orphaned-payment auto-refund)" do
      it "logs and returns without raising" do
        refund = build_refund(payment_intent: "pi_no_card")

        expect { described_class.handle_refund_event(refund) }.not_to raise_error
        expect(Transaction.refunds.where("metadata->>'stripe_refund_id' = ?", refund.id)).to be_empty
      end
    end
  end

  describe ".handle_charge_refunded (defensive alias)" do
    it "fetches refunds from the API when the payload does not embed them (API >= 2022-11-15)" do
      refund = build_refund
      charge = OpenStruct.new(id: refund.charge, payment_intent: gift_card.payment_intent_id, refunds: nil)
      allow(Stripe::Refund).to receive(:list)
        .with(charge: charge.id)
        .and_return(OpenStruct.new(data: [refund]))

      described_class.handle_charge_refunded(charge)

      expect(gift_card.reload.status).to eq("canceled")
      expect(Transaction.refunds.find_by(processor_ref: refund.id)).to be_present
    end

    it "still consumes legacy payloads that embed the refunds list" do
      refund = build_refund
      charge = OpenStruct.new(
        id: refund.charge,
        payment_intent: gift_card.payment_intent_id,
        refunds: OpenStruct.new(data: [refund])
      )
      expect(Stripe::Refund).not_to receive(:list)

      described_class.handle_charge_refunded(charge)

      expect(gift_card.reload.status).to eq("canceled")
    end
  end

  describe ".handle_charge_dispute_closed" do
    def build_dispute(status:)
      OpenStruct.new(
        id: "dp_test_#{SecureRandom.hex(4)}",
        payment_intent: gift_card.payment_intent_id,
        status: status,
        reason: "fraudulent",
        amount: 5000
      )
    end

    it "cancels the card and writes off the balance when the dispute is LOST" do
      dispute = build_dispute(status: "lost")

      described_class.handle_charge_dispute_closed(dispute)

      gift_card.reload
      expect(gift_card.status).to eq("canceled")
      expect(gift_card.remaining_balance).to eq(0)

      txn = Transaction.find_by(processor_ref: "dispute_#{dispute.id}")
      expect(txn).to be_present
      expect(txn.txn_type).to eq("adjustment")
      expect(txn.amount).to eq(5000)
      expect(txn.metadata["source"]).to eq("dispute_lost")
    end

    it "is idempotent against re-delivery" do
      dispute = build_dispute(status: "lost")

      described_class.handle_charge_dispute_closed(dispute)
      described_class.handle_charge_dispute_closed(dispute)

      expect(Transaction.where(processor_ref: "dispute_#{dispute.id}").count).to eq(1)
    end

    it "does not cancel the card when the dispute is WON" do
      dispute = build_dispute(status: "won")

      described_class.handle_charge_dispute_closed(dispute)

      expect(gift_card.reload.status).to eq("active")
      expect(AdminAlertMailer).to have_received(:dispute_closed)
    end
  end

  describe ".handle_payment_intent_payment_failed" do
    let(:memory_cache) { ActiveSupport::Cache::MemoryStore.new }

    before { allow(Rails).to receive(:cache).and_return(memory_cache) }

    def build_failed_pi(id: "pi_failed_#{SecureRandom.hex(4)}")
      OpenStruct.new(
        id: id,
        amount: 800,
        currency: "usd",
        metadata: { "sender_id" => "30", "merchant_id" => "4" },
        last_payment_error: OpenStruct.new(code: "card_declined", decline_code: "do_not_honor")
      )
    end

    it "alerts admin on the first failure of a payment intent" do
      described_class.handle_payment_intent_payment_failed(build_failed_pi(id: "pi_once"))

      expect(AdminAlertMailer).to have_received(:payment_failed)
        .with("pi_once", 800, "USD", "card_declined", "do_not_honor", "30", "4")
    end

    it "throttles repeat failures of the same payment intent (retry storms)" do
      3.times { described_class.handle_payment_intent_payment_failed(build_failed_pi(id: "pi_storm")) }

      expect(AdminAlertMailer).to have_received(:payment_failed).once
    end

    it "never raises (visibility must not trigger Stripe retries)" do
      broken = OpenStruct.new(id: "pi_broken", amount: nil, currency: nil, metadata: nil)

      expect { described_class.handle_payment_intent_payment_failed(broken) }.not_to raise_error
    end

    it "persists a PaymentFailure row with the decline details" do
      described_class.handle_payment_intent_payment_failed(build_failed_pi(id: "pi_persist"))

      failure = PaymentFailure.find_by(payment_intent_id: "pi_persist")
      expect(failure).to be_present
      expect(failure.amount).to eq(800)
      expect(failure.decline_code).to eq("do_not_honor")
      expect(failure.error_code).to eq("card_declined")
      expect(failure.attempts).to eq(1)
      expect(failure.resolved_at).to be_nil
    end

    it "increments attempts on repeat failures instead of adding rows" do
      3.times { described_class.handle_payment_intent_payment_failed(build_failed_pi(id: "pi_retry")) }

      expect(PaymentFailure.where(payment_intent_id: "pi_retry").count).to eq(1)
      expect(PaymentFailure.find_by(payment_intent_id: "pi_retry").attempts).to eq(3)
    end
  end

  describe ".mark_payment_failures_resolved" do
    it "closes the decline record when the same PI later succeeds" do
      failure = PaymentFailure.create!(
        payment_intent_id: "pi_recovered", amount: 800, currency: "USD",
        first_failed_at: 1.hour.ago, last_failed_at: 1.hour.ago
      )

      described_class.mark_payment_failures_resolved(OpenStruct.new(id: "pi_recovered"))

      expect(failure.reload.resolved_at).to be_present
    end

    it "never raises even with a broken payment intent" do
      expect { described_class.mark_payment_failures_resolved(OpenStruct.new) }.not_to raise_error
    end
  end

  describe ".process_event routing" do
    it "routes refund.* events to the refund handler" do
      refund = build_refund
      %w[refund.created refund.updated refund.failed].each do |type|
        event = OpenStruct.new(type: type, data: OpenStruct.new(object: refund))
        expect { described_class.process_event(event) }.not_to raise_error
      end
    end

    it "routes payment_intent.payment_failed" do
      pi = OpenStruct.new(id: "pi_x", amount: 800, currency: "usd", metadata: {}, last_payment_error: nil)
      event = OpenStruct.new(type: "payment_intent.payment_failed", data: OpenStruct.new(object: pi))

      expect { described_class.process_event(event) }.not_to raise_error
    end
  end
end
