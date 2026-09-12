require "rails_helper"

# §10.2e deploy-transition shims: jobs serialized by the pre-Push-B code
# carry a GIFT CARD id. They must deliver that card's first load, never
# read the card id as a load id.
RSpec.describe NotificationJob, type: :job do
  let(:merchant) { create(:merchant, store_name: "Medicity") }
  let(:sender) { create(:user, first_name: "Ana") }
  let(:recipient) { create(:user, first_name: "Rita", email: "shim-recipient@example.com") }
  let(:gift_card) { create(:gift_card, recipient:, merchant:, amount: 0) }

  before { allow(LoadNotificationJob).to receive(:perform_now) }

  it "delivers the card's first load (legacy card-id argument, legacy raw code tolerated)" do
    first = stripe_load!(gift_card, 3_000, sender: sender, at: 2.days.ago)
    stripe_load!(gift_card, 2_000, sender: sender)

    described_class.perform_now(gift_card.id, "LEGACY-RAW-CODE")

    expect(LoadNotificationJob).to have_received(:perform_now).with(first.id)
  end

  it "retries later (LoadNotReady) when the old webhook's card has no load yet" do
    gift_card # created, no loads — waits for ledger:backfill_missing_loads
    expect { described_class.perform_now(gift_card.id) }.to have_enqueued_job(described_class).with(gift_card.id)
    expect(LoadNotificationJob).not_to have_received(:perform_now)
  end

  it "logs and returns for an unknown card" do
    expect { described_class.perform_now(-1) }.not_to raise_error
    expect(LoadNotificationJob).not_to have_received(:perform_now)
  end
end

RSpec.describe ResendNotificationJob, type: :job do
  let(:merchant) { create(:merchant) }
  let(:gift_card) { create(:gift_card, recipient: create(:user), merchant:, amount: 0) }

  before { allow(LoadResendNotificationJob).to receive(:perform_now) }

  it "resends the card's first load for a legacy card-id job" do
    first = stripe_load!(gift_card, 1_000, sender: create(:user))
    described_class.perform_now(gift_card.id)
    expect(LoadResendNotificationJob).to have_received(:perform_now).with(first.id)
  end

  it "does nothing for a card without loads or an unknown id" do
    described_class.perform_now(gift_card.id)
    described_class.perform_now(-1)
    expect(LoadResendNotificationJob).not_to have_received(:perform_now)
  end
end
