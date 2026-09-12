require "rails_helper"

# §5.9: notifications are per LOAD — first load vs reload templates,
# self-load suppression, delivery flags on the load (no double-send).
RSpec.describe LoadNotificationJob, type: :job do
  let(:merchant) { create(:merchant, store_name: "Medicity") }
  let(:sender) { create(:user, first_name: "Ana", last_name: "Sender") }
  let(:recipient) { create(:user, first_name: "Rita", email: "recipient-job@example.com", phone: "+15550009999") }
  let(:gift_card) { create(:gift_card, recipient:, merchant:, amount: 0) }
  let(:pusher) { instance_double(Messaging::PushSender) }

  before do
    allow(Messaging::PushSender).to receive(:new).and_return(pusher)
    allow(pusher).to receive(:send_to_user).and_return({ success: true })
    allow(Messaging::TwilioConfig).to receive(:enabled?).and_return(false)
  end

  def load!(cents, **attrs)
    stripe_load!(gift_card, cents, **{ sender: sender }.merge(attrs))
  end

  it "sends the first-load templates (email + push gift_card_received) and flags the load" do
    load = load!(3_000)

    expect { described_class.perform_now(load.id) }.to have_enqueued_mail(GiftCardMailer, :deliver_gift_card).with(load)

    expect(pusher).to have_received(:send_to_user).with(
      recipient,
      title: "🎁 Tarjeta de regalo de Medicity",
      body: "Ana te envió $30.00 para usar en Medicity.",
      data: { gift_card_id: gift_card.id.to_s, load_id: load.id.to_s, type: "gift_card_received" }
    )
    expect(load.reload).to have_attributes(sent_via_email: true, sent_via_push: true, sent_via_whatsapp: false, sent_via_sms: false)
    expect(gift_card.reload.sent_via_email).to be(false) # flags live on the load now
  end

  it "sends the reload template with the spendable balance (gift_card_topped_up)" do
    load!(3_000, at: 1.day.ago)
    other = create(:user, first_name: "Luis")
    reload = load!(2_000, sender: other)

    described_class.perform_now(reload.id)

    expect(pusher).to have_received(:send_to_user).with(
      recipient,
      title: "Recarga en tu tarjeta de Medicity",
      body: "Luis añadió $20.00. Saldo disponible: $50.00.",
      data: { gift_card_id: gift_card.id.to_s, load_id: reload.id.to_s, type: "gift_card_topped_up" }
    )
  end

  it "sends only a push for a self-load (no WhatsApp/SMS/email)" do
    allow(Messaging::TwilioConfig).to receive(:enabled?).and_return(true)
    load = load!(1_500, sender: recipient)

    expect { described_class.perform_now(load.id) }.not_to have_enqueued_mail(GiftCardMailer, :deliver_gift_card)

    expect(pusher).to have_received(:send_to_user).with(
      recipient,
      title: "Recarga confirmada",
      body: "$15.00 en tu tarjeta de Medicity.",
      data: { gift_card_id: gift_card.id.to_s, load_id: load.id.to_s, type: "gift_card_topped_up" }
    )
    expect(load.reload.sent_via_push).to be(true)
  end

  it "logs and returns for an unknown load" do
    expect { described_class.perform_now(-1) }.not_to raise_error
    expect(pusher).not_to have_received(:send_to_user)
  end

  describe "phone templates (§4.4)" do
    let(:twilio) { double("twilio") }
    let(:messages) { double("messages") }

    before do
      allow(Messaging::TwilioConfig).to receive_messages(enabled?: true, client: twilio, whatsapp_number: "+10000000000", from_number: "+10000000001")
      allow(twilio).to receive(:messages).and_return(messages)
      allow(messages).to receive(:create).and_return(double(sid: "SM1"))
    end

    it "first load carries the digital gift card wording and the claim link" do
      load = load!(3_000)
      described_class.perform_now(load.id)

      expect(messages).to have_received(:create).with(hash_including(to: "whatsapp:+15550009999")) do |args|
        expect(args[:body]).to eq("¡Hola Rita! Ana te envió una tarjeta de regalo digital de Medicity por $30.00 en Papayal. Descarga la app y reclámala con este número: #{AppLinks.claim_url(GiftCards::ClaimLink.issue!(load))}")
      end
      expect(load.reload.sent_via_whatsapp).to be(true)
    end

    it "reload states the spendable balance and no link for a claimed recipient" do
      load!(3_000, at: 1.day.ago)
      reload = load!(2_000)
      described_class.perform_now(reload.id)

      expect(messages).to have_received(:create) do |args|
        expect(args[:body]).to eq("¡Hola Rita! Ana añadió $20.00 a tu tarjeta de Medicity en Papayal. Saldo disponible: $50.00.")
      end
    end
  end

  describe "Sidekiq retry after partial failure" do
    it "skips channels whose delivery flag is already set (no double-send)" do
      load = load!(1_000, sent_via_email: true, sent_via_whatsapp: true)

      notifier = Messaging::Notifier.new(load)
      allow(Messaging::Notifier).to receive(:new).and_return(notifier)
      allow(notifier).to receive(:send_push).and_return({ success: false, error: "no tokens" })
      expect(notifier).not_to receive(:send_email)
      expect(notifier).not_to receive(:send_phone_channel)

      described_class.perform_now(load.id)
    end

    it "still sends the channels that have not been delivered yet" do
      load = load!(1_000, sent_via_whatsapp: true)

      notifier = Messaging::Notifier.new(load)
      allow(Messaging::Notifier).to receive(:new).and_return(notifier)
      allow(notifier).to receive(:send_email).and_return({ success: true })
      allow(notifier).to receive(:send_push).and_return({ success: false, error: "no tokens" })
      expect(notifier).not_to receive(:send_phone_channel)

      described_class.perform_now(load.id)

      expect(notifier).to have_received(:send_email)
      expect(load.reload.sent_via_email).to be(true)
    end
  end
end
