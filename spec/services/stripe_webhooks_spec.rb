require "rails_helper"
require "ostruct"

RSpec.describe StripeWebhooks do
  let(:sender) { create(:user) }
  let!(:merchant) { create(:merchant) }

  before do
    allow(NotificationJob).to receive(:perform_later)
    allow(NotificationJob).to receive(:perform_now)
    allow(Refunds::RefundOrphanedPayment).to receive(:call)
  end

  def build_payment_intent(metadata_overrides = {}, latest_charge: nil)
    metadata = {
      "sender_id" => sender.id.to_s,
      "recipient_email" => "recipient@example.com",
      "recipient_name" => "Recipient Person",
      "recipient_phone" => "+15550001234",
      "merchant_id" => merchant.id.to_s
    }.merge(metadata_overrides)

    OpenStruct.new(
      id: "pi_test_#{SecureRandom.hex(4)}",
      metadata: metadata,
      amount: 1_500,
      currency: "usd",
      receipt_email: "buyer@example.com",
      latest_charge: latest_charge
    )
  end

  def build_charge(risk_score: nil, risk_level: nil, outcome: :radar)
    outcome_struct =
      if outcome == :radar
        OpenStruct.new(risk_score: risk_score, risk_level: risk_level)
      end

    OpenStruct.new(id: "ch_test_#{SecureRandom.hex(4)}", outcome: outcome_struct)
  end

  describe ".handle_payment_intent_succeeded" do
    context "happy path" do
      it "creates the gift card and does not refund" do
        payment_intent = build_payment_intent

        expect {
          described_class.handle_payment_intent_succeeded(payment_intent)
        }.to change(GiftCard, :count).by(1)

        gift_card = GiftCard.find_by(payment_intent_id: payment_intent.id)
        expect(gift_card.amount).to eq(1_500)
        expect(gift_card.sender).to eq(sender)
        expect(gift_card.merchant).to eq(merchant)
        expect(Refunds::RefundOrphanedPayment).not_to have_received(:call)
      end

      it "is idempotent when the gift card already exists" do
        payment_intent = build_payment_intent
        described_class.handle_payment_intent_succeeded(payment_intent)

        expect {
          described_class.handle_payment_intent_succeeded(payment_intent)
        }.not_to change(GiftCard, :count)
        expect(Refunds::RefundOrphanedPayment).not_to have_received(:call)
      end

      it "uses metadata subtotal as the card face value when a buyer fee was charged" do
        payment_intent = build_payment_intent({
          "subtotal_cents" => "1400",
          "fee_cents" => "100"
        })

        described_class.handle_payment_intent_succeeded(payment_intent)

        gift_card = GiftCard.find_by(payment_intent_id: payment_intent.id)
        expect(gift_card.amount).to eq(1_400)
        expect(gift_card.remaining_balance).to eq(1_400)

        purchase = gift_card.transactions.find_by(txn_type: :purchase)
        expect(purchase.amount).to eq(1_400)
        expect(purchase.metadata["subtotal_cents"]).to eq(1_400)
        expect(purchase.metadata["fee_cents"]).to eq(100)
        expect(purchase.metadata["total_paid_cents"]).to eq(1_500)
      end

      it "falls back to the charged amount when subtotal metadata is nonsensical" do
        payment_intent = build_payment_intent({ "subtotal_cents" => "999999" })

        described_class.handle_payment_intent_succeeded(payment_intent)

        gift_card = GiftCard.find_by(payment_intent_id: payment_intent.id)
        expect(gift_card.amount).to eq(1_500)
      end
    end

    context "Radar risk assessment" do
      it "places a security hold when the risk score meets the threshold" do
        charge = build_charge(risk_score: GiftCard::RISK_HOLD_THRESHOLD, risk_level: "elevated")
        allow(Stripe::Charge).to receive(:retrieve).with({ id: charge.id, expand: ["balance_transaction"] }).and_return(charge)
        payment_intent = build_payment_intent(latest_charge: charge.id)

        described_class.handle_payment_intent_succeeded(payment_intent)

        gift_card = GiftCard.find_by(payment_intent_id: payment_intent.id)
        expect(gift_card.risk_score).to eq(GiftCard::RISK_HOLD_THRESHOLD)
        expect(gift_card.risk_level).to eq("elevated")
        expect(gift_card.held_until).to be_present
        expect(gift_card).to be_held
      end

      it "does not hold when the risk score is below the threshold" do
        charge = build_charge(risk_score: GiftCard::RISK_HOLD_THRESHOLD - 1, risk_level: "normal")
        allow(Stripe::Charge).to receive(:retrieve).with({ id: charge.id, expand: ["balance_transaction"] }).and_return(charge)
        payment_intent = build_payment_intent(latest_charge: charge.id)

        described_class.handle_payment_intent_succeeded(payment_intent)

        gift_card = GiftCard.find_by(payment_intent_id: payment_intent.id)
        expect(gift_card.risk_score).to eq(GiftCard::RISK_HOLD_THRESHOLD - 1)
        expect(gift_card.risk_level).to eq("normal")
        expect(gift_card.held_until).to be_nil
      end

      it "reads the outcome directly when latest_charge is already an expanded charge object" do
        # If the code tried to re-fetch the expanded charge this would raise,
        # get rescued, and zero the score — failing the expectations below.
        allow(Stripe::Charge).to receive(:retrieve).and_raise("latest_charge was already expanded")
        charge = build_charge(risk_score: 80, risk_level: "highest")
        payment_intent = build_payment_intent(latest_charge: charge)

        described_class.handle_payment_intent_succeeded(payment_intent)

        gift_card = GiftCard.find_by(payment_intent_id: payment_intent.id)
        expect(gift_card.risk_score).to eq(80)
        expect(gift_card.held_until).to be_present
      end

      it "treats a missing latest_charge as zero risk and does not hold" do
        payment_intent = build_payment_intent(latest_charge: nil)

        described_class.handle_payment_intent_succeeded(payment_intent)

        gift_card = GiftCard.find_by(payment_intent_id: payment_intent.id)
        expect(gift_card.risk_score).to eq(0)
        expect(gift_card.risk_level).to be_nil
        expect(gift_card.held_until).to be_nil
      end

      it "treats a charge without a Radar outcome as zero risk (test charges)" do
        charge = build_charge(outcome: nil)
        allow(Stripe::Charge).to receive(:retrieve).with({ id: charge.id, expand: ["balance_transaction"] }).and_return(charge)
        payment_intent = build_payment_intent(latest_charge: charge.id)

        described_class.handle_payment_intent_succeeded(payment_intent)

        gift_card = GiftCard.find_by(payment_intent_id: payment_intent.id)
        expect(gift_card.risk_score).to eq(0)
        expect(gift_card.held_until).to be_nil
      end

      it "falls back to zero risk when the charge lookup fails" do
        allow(Stripe::Charge).to receive(:retrieve)
          .and_raise(Stripe::APIConnectionError.new("down"))
        payment_intent = build_payment_intent(latest_charge: "ch_gone")

        described_class.handle_payment_intent_succeeded(payment_intent)

        gift_card = GiftCard.find_by(payment_intent_id: payment_intent.id)
        expect(gift_card.risk_score).to eq(0)
        expect(gift_card.held_until).to be_nil
      end
    end

    context "permanent fulfillment failures auto-refund the buyer" do
      it "refunds when merchant_id is missing" do
        payment_intent = build_payment_intent({ "merchant_id" => "" })

        expect {
          described_class.handle_payment_intent_succeeded(payment_intent)
        }.not_to change(GiftCard, :count)
        expect(Refunds::RefundOrphanedPayment).to have_received(:call)
          .with(payment_intent: payment_intent, reason: "merchant_invalid")
      end

      it "refunds when the merchant does not exist" do
        payment_intent = build_payment_intent({ "merchant_id" => "999999" })

        described_class.handle_payment_intent_succeeded(payment_intent)
        expect(Refunds::RefundOrphanedPayment).to have_received(:call)
          .with(payment_intent: payment_intent, reason: "merchant_invalid")
      end

      it "refunds when the merchant was suspended after checkout" do
        merchant.update!(status: :suspended)
        payment_intent = build_payment_intent

        described_class.handle_payment_intent_succeeded(payment_intent)
        expect(Refunds::RefundOrphanedPayment).to have_received(:call)
          .with(payment_intent: payment_intent, reason: "merchant_inactive")
      end

      it "refunds when the sender no longer exists" do
        payment_intent = build_payment_intent({ "sender_id" => "999999" })

        described_class.handle_payment_intent_succeeded(payment_intent)
        expect(Refunds::RefundOrphanedPayment).to have_received(:call)
          .with(payment_intent: payment_intent, reason: "sender_missing")
      end

      it "refunds when the amount exceeds the per-card maximum" do
        payment_intent = build_payment_intent
        payment_intent.amount = GiftCard::MAX_AMOUNT_CENTS + 1

        described_class.handle_payment_intent_succeeded(payment_intent)
        expect(Refunds::RefundOrphanedPayment).to have_received(:call)
          .with(payment_intent: payment_intent, reason: "amount_exceeds_max")
      end

      it "refunds the excess purchase when the 24h limit was exceeded (checkout TOCTOU race)" do
        allow(GiftCardPurchaseLimiter).to receive(:can_purchase?)
          .and_return({ allowed: false, count: 5, limit: 5, reason: "limit" })
        payment_intent = build_payment_intent

        expect {
          described_class.handle_payment_intent_succeeded(payment_intent)
        }.not_to change(GiftCard, :count)
        expect(Refunds::RefundOrphanedPayment).to have_received(:call)
          .with(payment_intent: payment_intent, reason: "purchase_limit_exceeded")
      end
    end

    context "refund resiliency" do
      it "does not refund when a concurrent delivery created the card mid-failure-handling" do
        payment_intent = build_payment_intent({ "merchant_id" => "" })
        allow(Refunds::RefundOrphanedPayment).to receive(:call)
          .and_raise(Refunds::RefundOrphanedPayment::GiftCardExists)

        expect {
          described_class.handle_payment_intent_succeeded(payment_intent)
        }.not_to raise_error
      end

      it "propagates refund failures so Stripe redelivers the webhook" do
        payment_intent = build_payment_intent({ "merchant_id" => "" })
        allow(Refunds::RefundOrphanedPayment).to receive(:call)
          .and_raise(Stripe::APIConnectionError.new("down"))

        expect {
          described_class.handle_payment_intent_succeeded(payment_intent)
        }.to raise_error(Stripe::APIConnectionError)
      end

      it "re-raises transient errors without refunding so Stripe retries" do
        payment_intent = build_payment_intent
        allow(GiftCard).to receive(:create!).and_raise(ActiveRecord::ConnectionNotEstablished)

        expect {
          described_class.handle_payment_intent_succeeded(payment_intent)
        }.to raise_error(ActiveRecord::ConnectionNotEstablished)
        expect(Refunds::RefundOrphanedPayment).not_to have_received(:call)
      end
    end
  end
end
