require "rails_helper"
require "ostruct"

# Refund/dispute reconciliation per LOAD (§5.7, §5.8): the paths that keep
# the internal ledger in sync with money movements that happen at Stripe
# (dashboard refunds, admin refunds, failed refunds, chargebacks, declined
# payments).
RSpec.describe StripeWebhooks do
  let(:merchant) { create(:merchant) }
  let(:buyer) { create(:user) }
  let(:other_buyer) { create(:user) }
  let(:gift_card) { create(:gift_card, merchant: merchant, amount: 0) }
  let!(:load) { stripe_load!(gift_card, 5000, sender: buyer, payment_intent_id: "pi_refund_test_#{SecureRandom.hex(4)}", at: 2.days.ago) }

  def build_refund(overrides = {})
    OpenStruct.new(
      {
        id: "re_test_#{SecureRandom.hex(4)}",
        amount: 5000,
        currency: "usd",
        status: "succeeded",
        payment_intent: load.payment_intent_id,
        charge: "ch_test_#{SecureRandom.hex(4)}",
        reason: "requested_by_customer",
        failure_reason: nil
      }.merge(overrides)
    )
  end

  before do
    allow(AdminAlertMailer).to receive(:refund_failed).and_return(double(deliver_later: true))
    allow(AdminAlertMailer).to receive(:payment_failed).and_return(double(deliver_later: true))
    allow(AdminAlertMailer).to receive(:dispute_created).and_return(double(deliver_later: true))
    allow(AdminAlertMailer).to receive(:dispute_closed).and_return(double(deliver_later: true))
    allow(AdminAlertMailer).to receive(:over_refund).and_return(double(deliver_later: true))
    allow(AdminAlertMailer).to receive(:buyer_purchases_blocked).and_return(double(deliver_later: true))
  end

  describe ".handle_refund_event" do
    context "full refund (succeeded)" do
      it "empties the load, keeps the card active, and records a ledger row on the load" do
        refund = build_refund

        described_class.handle_refund_event(refund)

        gift_card.reload
        expect(gift_card.status).to eq("active") # never canceled by a refund (§5.7)
        expect(gift_card.remaining_balance).to eq(0)
        expect(load.reload).to have_attributes(remaining_cents: 0, refunded_cents: 5000, status: "refunded")

        txn = Transaction.refunds.find_by(processor_ref: refund.id)
        expect(txn).to be_present
        expect(txn.status).to eq("succeeded")
        expect(txn.amount).to eq(5000)
        expect(txn.gift_card_load_id).to eq(load.id)
        expect(txn.metadata["stripe_refund_id"]).to eq(refund.id)
        expect(txn.metadata["source"]).to eq("stripe_webhook")
        expect(txn.metadata["over_refund_cents"]).to eq(0)
        expect(gift_card.verify_ledger!).to be(true)
      end
    end

    context "partial refund" do
      it "reduces only that load and leaves other loads and the card alone" do
        other = stripe_load!(gift_card, 2000, sender: other_buyer)
        refund = build_refund(amount: 2000)

        described_class.handle_refund_event(refund)

        gift_card.reload
        expect(gift_card.status).to eq("active")
        expect(gift_card.remaining_balance).to eq(5000)
        expect(load.reload).to have_attributes(remaining_cents: 3000, refunded_cents: 2000, status: "available")
        expect(other.reload.remaining_cents).to eq(2000)
        expect(gift_card.verify_ledger!).to be(true)
      end
    end

    context "refund larger than what is still on the load (already spent at a merchant)" do
      it "does not floor silently: records the over-refund and alerts admin" do
        redeem_card!(gift_card, 3000, merchant: merchant)
        refund = build_refund(amount: 5000)

        described_class.handle_refund_event(refund)

        expect(load.reload).to have_attributes(remaining_cents: 0, refunded_cents: 2000) # only what left the load
        expect(gift_card.reload.remaining_balance).to eq(0)
        expect(gift_card.verify_ledger!).to be(true)
        txn = Transaction.refunds.find_by(processor_ref: refund.id)
        expect(txn.metadata["debited_cents"]).to eq(2000)
        expect(txn.metadata["over_refund_cents"]).to eq(3000)
        expect(AdminAlertMailer).to have_received(:over_refund).with(gift_card.id, load.id, refund.id, 3000, "USD")
      end
    end

    context "re-delivery / overlapping events (refund.created then refund.updated)" do
      it "records the refund exactly once" do
        refund = build_refund

        described_class.handle_refund_event(refund)
        described_class.handle_refund_event(refund)

        expect(Transaction.refunds.where("metadata->>'stripe_refund_id' = ?", refund.id).count).to eq(1)
        expect(gift_card.reload.remaining_balance).to eq(0)
        expect(load.reload.refunded_cents).to eq(5000)
      end
    end

    context "pending refund" do
      it "debits immediately (refund.failed reverses later if needed)" do
        refund = build_refund(status: "pending")
        described_class.handle_refund_event(refund)
        expect(load.reload.remaining_cents).to eq(0)
      end
    end

    context "refund fails after being applied" do
      it "restores the load, marks the ledger row failed, and alerts admin" do
        refund = build_refund
        described_class.handle_refund_event(refund)
        expect(load.reload.remaining_cents).to eq(0)

        failed = build_refund(id: refund.id, status: "failed", failure_reason: "unknown")
        described_class.handle_refund_event(failed)

        expect(load.reload).to have_attributes(remaining_cents: 5000, refunded_cents: 0, status: "available")
        expect(gift_card.reload.remaining_balance).to eq(5000)

        txn = Transaction.find_by(processor_ref: refund.id)
        expect(txn.status).to eq("failed")
        expect(txn.metadata["refund_failure_reason"]).to eq("unknown")
        expect(AdminAlertMailer).to have_received(:refund_failed).with(gift_card.id, refund.id, 5000, "USD", "unknown")
        expect(gift_card.verify_ledger!).to be(true)
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

    context "no load for the payment intent (orphaned-payment auto-refund)" do
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
      charge = OpenStruct.new(id: refund.charge, payment_intent: load.payment_intent_id, refunds: nil)
      allow(Stripe::Refund).to receive(:list).with(charge: charge.id).and_return(OpenStruct.new(data: [refund]))

      described_class.handle_charge_refunded(charge)

      expect(load.reload.status).to eq("refunded")
      expect(Transaction.refunds.find_by(processor_ref: refund.id)).to be_present
    end

    it "still consumes legacy payloads that embed the refunds list" do
      refund = build_refund
      charge = OpenStruct.new(id: refund.charge, payment_intent: load.payment_intent_id, refunds: OpenStruct.new(data: [refund]))
      expect(Stripe::Refund).not_to receive(:list)

      described_class.handle_charge_refunded(charge)

      expect(load.reload.status).to eq("refunded")
    end
  end

  describe "disputes (per load, D4)" do
    def build_dispute(status: nil, id: "dp_test_#{SecureRandom.hex(4)}", for_load: load)
      OpenStruct.new(id: id, payment_intent: for_load.payment_intent_id, status: status, reason: "fraudulent", amount: for_load.amount_cents)
    end

    describe ".handle_charge_dispute_created" do
      it "takes only the disputed load out of spendable, blocks the buyer, leaves the card active" do
        other = stripe_load!(gift_card, 2000, sender: other_buyer)
        dispute = build_dispute

        described_class.handle_charge_dispute_created(dispute)

        expect(load.reload).to have_attributes(dispute_id: dispute.id, dispute_outcome: nil, status: "disputed")
        expect(load.disputed_at).to be_present
        expect(other.reload.status).to eq("available")
        expect(gift_card.reload.status).to eq("active")
        expect(gift_card.balances).to include(remaining_balance: 7000, disputed_cents: 5000, spendable_cents: 2000)
        expect(buyer.reload.dispute_open_count).to eq(1)
        expect(buyer).to be_purchases_blocked
        expect(other_buyer.reload.dispute_open_count).to eq(0)
        expect(AdminAlertMailer).to have_received(:dispute_created).with(gift_card.id, dispute.id)
      end

      it "is idempotent against re-delivery" do
        dispute = build_dispute
        described_class.handle_charge_dispute_created(dispute)
        described_class.handle_charge_dispute_created(dispute)
        expect(buyer.reload.dispute_open_count).to eq(1)
        expect(AdminAlertMailer).to have_received(:dispute_created).once
      end

      it "ignores a dispute whose payment intent has no load" do
        expect { described_class.handle_charge_dispute_created(OpenStruct.new(id: "dp_x", payment_intent: "pi_none", reason: "x", amount: 1)) }
          .not_to raise_error
      end
    end

    describe ".handle_charge_dispute_closed" do
      it "WON: funds return to spendable and the buyer is unblocked" do
        dispute = build_dispute
        described_class.handle_charge_dispute_created(dispute)

        described_class.handle_charge_dispute_closed(build_dispute(id: dispute.id, status: "won"))

        expect(load.reload).to have_attributes(dispute_outcome: "won", status: "available")
        expect(load.disputed_at).to be_present # kept for audit
        expect(gift_card.reload.balances).to include(disputed_cents: 0, spendable_cents: 5000)
        expect(buyer.reload.dispute_open_count).to eq(0)
        expect(buyer).not_to be_purchases_blocked
        expect(AdminAlertMailer).to have_received(:dispute_closed).with(gift_card.id, dispute.id, "won")
      end

      it "LOST: writes off only that load's remaining cents; the card stays active with the other money" do
        other = stripe_load!(gift_card, 2000, sender: other_buyer)
        redeem_card!(gift_card, 1000, merchant: merchant) # FIFO: spent 1000 of the disputed load
        dispute = build_dispute
        described_class.handle_charge_dispute_created(dispute)

        described_class.handle_charge_dispute_closed(build_dispute(id: dispute.id, status: "lost"))

        expect(load.reload).to have_attributes(remaining_cents: 0, written_off_cents: 4000, dispute_outcome: "lost", status: "written_off")
        expect(other.reload.remaining_cents).to eq(2000)
        gift_card.reload
        expect(gift_card.status).to eq("active")
        expect(gift_card.remaining_balance).to eq(2000)

        txn = Transaction.find_by(processor_ref: "dispute_#{dispute.id}")
        expect(txn).to have_attributes(txn_type: "adjustment", amount: 4000, gift_card_load_id: load.id)
        expect(txn.metadata["source"]).to eq("dispute_lost")
        expect(txn.metadata["spent_before_dispute_cents"]).to eq(1000)
        expect(buyer.reload).to have_attributes(dispute_open_count: 0, dispute_lost_count: 1)
        expect(buyer).not_to be_purchases_blocked
        expect(gift_card.verify_ledger!).to be(true)
      end

      it "LOST is idempotent against re-delivery" do
        dispute = build_dispute
        described_class.handle_charge_dispute_created(dispute)
        closed = build_dispute(id: dispute.id, status: "lost")

        described_class.handle_charge_dispute_closed(closed)
        described_class.handle_charge_dispute_closed(closed)

        expect(Transaction.where(processor_ref: "dispute_#{dispute.id}").count).to eq(1)
        expect(load.reload.written_off_cents).to eq(5000)
        expect(buyer.reload.dispute_lost_count).to eq(1)
      end

      it "blocks the buyer after a second lost dispute and alerts admin" do
        second_card = create(:gift_card, merchant: merchant, amount: 0)
        second_load = stripe_load!(second_card, 1500, sender: buyer)
        d1 = build_dispute
        d2 = build_dispute(for_load: second_load)
        described_class.handle_charge_dispute_created(d1)
        described_class.handle_charge_dispute_created(d2)
        expect(buyer.reload.dispute_open_count).to eq(2)

        described_class.handle_charge_dispute_closed(build_dispute(id: d1.id, status: "lost"))
        expect(buyer.reload.purchases_blocked_at).to be_nil

        described_class.handle_charge_dispute_closed(build_dispute(id: d2.id, status: "lost", for_load: second_load))
        expect(buyer.reload).to have_attributes(dispute_open_count: 0, dispute_lost_count: 2)
        expect(buyer.purchases_blocked_at).to be_present
        expect(AdminAlertMailer).to have_received(:buyer_purchases_blocked).with(buyer.id, d2.id)
      end
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
