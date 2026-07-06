require "rails_helper"

RSpec.describe NotificationJob, type: :job do
  let(:recipient) { create(:user, email: "recipient-job@example.com", phone: "+15550009999") }
  let(:gift_card) { create(:gift_card, recipient:) }

  it "sends notifications when given only the gift card id" do
    notifier = instance_double(
      Messaging::Notifier,
      send_all_notifications: { email: { success: true } }
    )
    allow(Messaging::Notifier).to receive(:new).and_return(notifier)

    described_class.perform_now(gift_card.id)

    expect(notifier).to have_received(:send_all_notifications)
  end

  it "still deserializes legacy jobs enqueued with a raw code second argument" do
    notifier = instance_double(
      Messaging::Notifier,
      send_all_notifications: { email: { success: true } }
    )
    allow(Messaging::Notifier).to receive(:new).and_return(notifier)

    expect {
      described_class.perform_now(gift_card.id, "LEGACY-RAW-CODE")
    }.not_to raise_error

    expect(notifier).to have_received(:send_all_notifications)
  end

  describe "Sidekiq retry after partial failure" do
    it "skips channels whose delivery flag is already set (no double-send)" do
      gift_card.update!(sent_via_email: true, sent_via_whatsapp: true)

      notifier = Messaging::Notifier.new(gift_card)
      allow(Messaging::Notifier).to receive(:new).and_return(notifier)
      allow(notifier).to receive(:send_push).and_return({ success: false, error: "no tokens" })
      expect(notifier).not_to receive(:send_email)
      expect(notifier).not_to receive(:send_phone_channel)

      described_class.perform_now(gift_card.id)
    end

    it "still sends the channels that have not been delivered yet" do
      gift_card.update!(sent_via_whatsapp: true)

      notifier = Messaging::Notifier.new(gift_card)
      allow(Messaging::Notifier).to receive(:new).and_return(notifier)
      allow(notifier).to receive(:send_email).and_return({ success: true })
      allow(notifier).to receive(:send_push).and_return({ success: false, error: "no tokens" })
      expect(notifier).not_to receive(:send_phone_channel)

      described_class.perform_now(gift_card.id)

      expect(notifier).to have_received(:send_email)
      expect(gift_card.reload.sent_via_email).to be(true)
    end
  end
end
