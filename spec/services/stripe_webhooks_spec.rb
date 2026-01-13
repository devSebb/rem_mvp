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
    end
  end
end

