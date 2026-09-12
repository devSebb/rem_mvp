require "rails_helper"
require "ostruct"

# §5.2 fulfilment: first load creates the card, later loads credit it,
# self-reload, duplicate deliveries, caps and card state → orphan refund,
# held/disputed loads leave other money alone (§12.1).
RSpec.describe Loads::Fulfill do
  let(:sender) { create(:user) }
  let!(:merchant) { create(:merchant) }
  let!(:recipient) { create(:user, email: "recipient@example.com", phone: "+15550001234") }

  before do
    allow(LoadNotificationJob).to receive(:perform_later)
    allow(LoadNotificationJob).to receive(:perform_now)
    allow(Refunds::RefundOrphanedPayment).to receive(:call)
    allow(GiftCardHoldMailer).to receive(:held).and_return(double(deliver_later: true))
    allow(PurchaseConfirmationMailer).to receive(:receipt).and_return(double(deliver_later: true))
  end

  def build_payment_intent(metadata_overrides = {}, amount: 1_500, latest_charge: nil, id: "pi_test_#{SecureRandom.hex(4)}")
    metadata = {
      "sender_id" => sender.id.to_s,
      "recipient_email" => "recipient@example.com",
      "recipient_name" => "Recipient Person",
      "recipient_phone" => "+15550001234",
      "merchant_id" => merchant.id.to_s
    }.merge(metadata_overrides)

    OpenStruct.new(id: id, metadata: metadata, amount: amount, currency: "usd",
                   receipt_email: "buyer@example.com", latest_charge: latest_charge)
  end

  def fulfill(pi)
    StripeWebhooks.handle_payment_intent_succeeded(pi)
  end

  it "creates the recipient's card at the merchant with one load, one purchase row and consistent counters" do
    pi = build_payment_intent({ "recipient_note" => "Para tus medicinas" })

    expect { fulfill(pi) }.to change(GiftCard, :count).by(1).and change(GiftCardLoad, :count).by(1)

    load = GiftCardLoad.for_payment_intent(pi.id)
    card = load.gift_card
    expect(card).to have_attributes(recipient_id: recipient.id, merchant_id: merchant.id, sender_id: sender.id, status: "active",
                                    remaining_balance: 1_500, total_loaded_cents: 1_500, amount: 1_500, loads_count: 1)
    expect(card.raw_code).to be_present
    expect(load).to have_attributes(sender_id: sender.id, source: "stripe", amount_cents: 1_500, remaining_cents: 1_500,
                                    fee_cents: 0, note: "Para tus medicinas", status: "available")
    purchase = card.transactions.purchases.sole
    expect(purchase).to have_attributes(amount: 1_500, gift_card_load_id: load.id, processor_ref: pi.id)
    expect(card.verify_ledger!).to be(true)
    expect(LoadNotificationJob).to have_received(:perform_later).with(load.id)
    expect(PurchaseConfirmationMailer).to have_received(:receipt).with(load.id)
    expect(Refunds::RefundOrphanedPayment).not_to have_received(:call)
  end

  it "credits a second payment onto the SAME card as a second load (D1/D2)" do
    first = build_payment_intent
    fulfill(first)
    other_buyer = create(:user)
    second = build_payment_intent({ "sender_id" => other_buyer.id.to_s }, amount: 3_000)

    expect { fulfill(second) }.not_to change(GiftCard, :count)

    card = GiftCard.find_by!(recipient_id: recipient.id, merchant_id: merchant.id)
    expect(card.loads.map(&:amount_cents)).to eq([1_500, 3_000])
    expect(card.loads.map(&:sender_id)).to eq([sender.id, other_buyer.id])
    expect(card).to have_attributes(remaining_balance: 4_500, total_loaded_cents: 4_500, loads_count: 2, sender_id: sender.id)
    expect(card.transactions.purchases.count).to eq(2)
    expect(card.verify_ledger!).to be(true)
  end

  it "handles a self-reload: sender is the recipient, no shell user" do
    pi = build_payment_intent({ "recipient_user_id" => sender.id.to_s, "recipient_email" => "", "recipient_phone" => "" })

    expect { fulfill(pi) }.to change(User, :count).by(0).and change(GiftCard, :count).by(1)
    card = GiftCard.find_by!(recipient_id: sender.id, merchant_id: merchant.id)
    expect(card.loads.sole.sender_id).to eq(sender.id)
  end

  it "creates a pending shell recipient when nobody matches the contact" do
    pi = build_payment_intent({ "recipient_email" => "new-person@example.com", "recipient_phone" => "+15550009876" })
    expect { fulfill(pi) }.to change(User, :count).by(1)
    shell = User.find_by!(email: "new-person@example.com")
    expect(shell).to be_pending
  end

  it "is idempotent on the payment intent" do
    pi = build_payment_intent
    fulfill(pi)

    expect { fulfill(pi) }.to not_change_count_of(GiftCardLoad).and not_change_count_of(Transaction)
    expect(Refunds::RefundOrphanedPayment).not_to have_received(:call)
  end

  it "does not double-credit when two deliveries race on the unique payment_intent index" do
    pi = build_payment_intent
    card = GiftCard.find_or_create_for!(recipient: recipient, merchant: merchant, first_sender: sender)
    # Simulate the other delivery winning between the idempotency check and the insert.
    allow(GiftCardLoad).to receive(:for_payment_intent).with(pi.id).and_return(nil)
    stripe_load!(card, 1_500, sender: sender, payment_intent_id: pi.id)

    expect { fulfill(pi) }.not_to change(GiftCardLoad, :count)
    expect(card.reload.remaining_balance).to eq(1_500)
    expect(Refunds::RefundOrphanedPayment).not_to have_received(:call)
  end

  describe "Radar holds are per load (D5)" do
    def charge_with(score)
      charge = OpenStruct.new(id: "ch_#{SecureRandom.hex(3)}", outcome: OpenStruct.new(risk_score: score, risk_level: "elevated"))
      allow(Stripe::Charge).to receive(:retrieve).with({ id: charge.id, expand: ["balance_transaction"] }).and_return(charge)
      charge
    end

    it "holds only the flagged load; earlier money stays spendable" do
      fulfill(build_payment_intent)
      charge = charge_with(GiftCard::RISK_HOLD_THRESHOLD)
      fulfill(build_payment_intent({ "sender_id" => create(:user).id.to_s }, amount: 2_000, latest_charge: charge.id))

      card = GiftCard.find_by!(recipient_id: recipient.id, merchant_id: merchant.id)
      held = card.loads.last
      expect(held).to be_held
      expect(held.risk_score).to eq(GiftCard::RISK_HOLD_THRESHOLD)
      expect(card.balances).to include(remaining_balance: 3_500, held_cents: 2_000, spendable_cents: 1_500)
      expect(card.held_until).to be_nil # deprecated card column untouched
      expect(GiftCardHoldMailer).to have_received(:held).with(held.id)
    end

    it "does not hold below the threshold" do
      charge = charge_with(GiftCard::RISK_HOLD_THRESHOLD - 1)
      fulfill(build_payment_intent(latest_charge: charge.id))
      load = GiftCardLoad.last
      expect(load).not_to be_held
      expect(load.risk_score).to eq(GiftCard::RISK_HOLD_THRESHOLD - 1)
    end
  end

  it "accepts a load from another buyer while one load is disputed (D4)" do
    fulfill(build_payment_intent)
    card = GiftCard.find_by!(recipient_id: recipient.id, merchant_id: merchant.id)
    card.loads.sole.update!(disputed_at: Time.current, dispute_id: "dp_1")
    sender.update!(dispute_open_count: 1)

    other = create(:user)
    fulfill(build_payment_intent({ "sender_id" => other.id.to_s }, amount: 2_000))

    expect(card.reload.loads_count).to eq(2)
    expect(card.balances).to include(remaining_balance: 3_500, disputed_cents: 1_500, spendable_cents: 2_000)
  end

  describe "permanent failures auto-refund the buyer" do
    it "refunds a buyer with an open dispute (I13)" do
      sender.update!(dispute_open_count: 1)
      pi = build_payment_intent

      expect { fulfill(pi) }.not_to change(GiftCardLoad, :count)
      expect(Refunds::RefundOrphanedPayment).to have_received(:call).with(payment_intent: pi, reason: "cap_exceeded:buyer_dispute_open")
    end

    it "refunds when a cap is exceeded at fulfilment time (checkout TOCTOU)" do
      PlatformSetting.current.update!(max_daily_loads_per_buyer: 1)
      fulfill(build_payment_intent)
      pi = build_payment_intent(amount: 1_000)

      fulfill(pi)
      expect(Refunds::RefundOrphanedPayment).to have_received(:call).with(payment_intent: pi, reason: "cap_exceeded:buyer_daily_count_limit")
    end

    it "refunds when the face value is outside the per-load range" do
      pi = build_payment_intent(amount: GiftCardLoad::MAX_LOAD_CENTS + 1)
      fulfill(pi)
      expect(Refunds::RefundOrphanedPayment).to have_received(:call).with(payment_intent: pi, reason: "cap_exceeded:load_amount_out_of_range")
    end

    it "refunds a load onto a canceled card and onto a frozen card" do
      card = GiftCard.find_or_create_for!(recipient: recipient, merchant: merchant, first_sender: sender)
      card.update_columns(status: GiftCard.statuses[:canceled])
      pi = build_payment_intent
      fulfill(pi)
      expect(Refunds::RefundOrphanedPayment).to have_received(:call).with(payment_intent: pi, reason: "card_canceled")

      card.update_columns(status: GiftCard.statuses[:frozen_by_admin], frozen_at: Time.current)
      pi2 = build_payment_intent
      fulfill(pi2)
      expect(Refunds::RefundOrphanedPayment).to have_received(:call).with(payment_intent: pi2, reason: "card_frozen")
      expect(card.reload.loads_count).to eq(0)
    end

    it "refunds when merchant, sender or recipient cannot be resolved" do
      fulfill(pi = build_payment_intent({ "merchant_id" => "" }))
      expect(Refunds::RefundOrphanedPayment).to have_received(:call).with(payment_intent: pi, reason: "merchant_invalid")
      fulfill(pi = build_payment_intent({ "sender_id" => "999999" }))
      expect(Refunds::RefundOrphanedPayment).to have_received(:call).with(payment_intent: pi, reason: "sender_missing")
      fulfill(pi = build_payment_intent({ "recipient_email" => "", "recipient_phone" => "" }))
      expect(Refunds::RefundOrphanedPayment).to have_received(:call).with(payment_intent: pi, reason: "recipient_missing")
    end
  end

  it "re-raises transient errors without refunding so Stripe retries" do
    pi = build_payment_intent
    allow(GiftCard).to receive(:find_or_create_for!).and_raise(ActiveRecord::ConnectionNotEstablished)

    expect { fulfill(pi) }.to raise_error(ActiveRecord::ConnectionNotEstablished)
    expect(Refunds::RefundOrphanedPayment).not_to have_received(:call)
  end

  RSpec::Matchers.define :not_change_count_of do |model|
    supports_block_expectations
    match do |block|
      before = model.count
      block.call
      model.count == before
    end
  end
end
