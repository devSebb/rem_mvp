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

end

