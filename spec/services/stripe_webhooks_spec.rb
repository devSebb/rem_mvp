require "rails_helper"
require "ostruct"

RSpec.describe StripeWebhooks do
  let(:sender) { create(:user) }
  let!(:merchant) { create(:merchant) }

  before do
    allow(NotificationJob).to receive(:perform_later)
    allow(NotificationJob).to receive(:perform_now)
  end

  def build_session(metadata_overrides = {})
    metadata = {
      "sender_id" => sender.id,
      "recipient_email" => "recipient@example.com",
      "recipient_name" => "Recipient",
      "recipient_phone" => "+1234567890",
      "merchant_id" => merchant.id
    }.merge(metadata_overrides)

    OpenStruct.new(
      id: "cs_test_#{SecureRandom.hex(4)}",
      metadata: metadata,
      amount_total: 1_500,
      currency: "usd",
      payment_intent: "pi_test_#{SecureRandom.hex(4)}",
      customer_email: "buyer@example.com"
    )
  end

  describe ".handle_checkout_session_completed" do
    it "raises when merchant_id is missing" do
      session = build_session("merchant_id" => nil)

      expect {
        described_class.send(:handle_checkout_session_completed, session)
      }.to raise_error(StripeWebhooks::InvalidMerchantError)

      expect(GiftCard.count).to eq(0)
    end

    it "raises when merchant_id is non-numeric" do
      session = build_session("merchant_id" => "abc")

      expect {
        described_class.send(:handle_checkout_session_completed, session)
      }.to raise_error(StripeWebhooks::InvalidMerchantError)

      expect(GiftCard.count).to eq(0)
    end

    it "raises when merchant_id is invalid" do
      session = build_session("merchant_id" => 999_999)

      expect {
        described_class.send(:handle_checkout_session_completed, session)
      }.to raise_error(StripeWebhooks::InvalidMerchantError)

      expect(GiftCard.count).to eq(0)
    end

    it "creates a gift card when merchant is valid" do
      session = build_session

      expect {
        described_class.send(:handle_checkout_session_completed, session)
      }.to change { GiftCard.count }.by(1)

      card = GiftCard.last
      expect(card.merchant_id).to eq(merchant.id)
      expect(card.checkout_session_id).to eq(session.id)
      expect(card.expires_at).to be_nil # Gift cards never expire
    end

    context "when amount exceeds maximum" do
      it "raises error when amount is greater than MAX_AMOUNT_CENTS" do
        session = build_session
        session.amount_total = GiftCard::MAX_AMOUNT_CENTS + 1

        expect {
          described_class.send(:handle_checkout_session_completed, session)
        }.to raise_error(StripeWebhooks::InvalidMerchantError, /Amount exceeds maximum/)

        expect(GiftCard.count).to eq(0)
      end

      it "allows amount exactly at MAX_AMOUNT_CENTS" do
        session = build_session
        session.amount_total = GiftCard::MAX_AMOUNT_CENTS

        expect {
          described_class.send(:handle_checkout_session_completed, session)
        }.to change { GiftCard.count }.by(1)
      end
    end

    context "when purchase limit is exceeded" do
      before do
        # Create 5 gift cards in the last 24 hours for the sender
        5.times do
          create(:gift_card, sender: sender, merchant: merchant, created_at: 1.hour.ago)
        end
      end

      it "raises error when user has reached 24h limit" do
        session = build_session

        expect {
          described_class.send(:handle_checkout_session_completed, session)
        }.to raise_error(StripeWebhooks::InvalidMerchantError, /Purchase limit exceeded/)

        expect(GiftCard.count).to eq(5) # No new gift card created
      end

      it "allows purchase when user has 4 purchases (under limit)" do
        # Delete one to have 4
        GiftCard.where(sender: sender).last.destroy

        session = build_session

        expect {
          described_class.send(:handle_checkout_session_completed, session)
        }.to change { GiftCard.count }.by(1)
      end

      it "allows purchase when oldest purchase is more than 24 hours ago" do
        # Update the oldest gift card to be 25 hours ago (use update_column to bypass callbacks)
        oldest_card = GiftCard.where(sender: sender).order(created_at: :asc).first
        oldest_card.update_column(:created_at, 25.hours.ago)

        session = build_session

        expect {
          described_class.send(:handle_checkout_session_completed, session)
        }.to change { GiftCard.count }.by(1)
      end
    end
  end
end

