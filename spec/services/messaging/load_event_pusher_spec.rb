require "rails_helper"

# §5.8 dispute push + §4.4 hold-released push, and the reconcile job wiring.
RSpec.describe Messaging::LoadEventPusher do
  let(:pusher) { instance_double(Messaging::PushSender, send_to_user: { success: true }) }
  let(:recipient) { create(:user) }
  let(:card) { create(:gift_card, recipient: recipient, merchant: create(:merchant, store_name: "Medicity"), amount: 0) }

  before { allow(Messaging::PushSender).to receive(:new).and_return(pusher) }

  it "tells the recipient a dispute took one reload out of spendable (from the webhook)" do
    load = stripe_load!(card, 3_000, sender: create(:user), payment_intent_id: "pi_disp_1")
    stripe_load!(card, 1_000, sender: create(:user))
    allow(AdminAlertMailer).to receive(:dispute_created).and_return(double(deliver_later: true))
    dispute = OpenStruct.new(id: "du_1", payment_intent: "pi_disp_1", reason: "fraudulent", amount: 3_000)

    StripeWebhooks.handle_charge_dispute_created(dispute)

    expect(pusher).to have_received(:send_to_user).with(
      recipient,
      title: "Una recarga está en revisión",
      body: "Una recarga de $30.00 está en revisión. El resto de tu saldo sigue disponible.",
      data: { type: "gift_card_load_disputed", gift_card_id: card.id.to_s, load_id: load.id.to_s }
    )
    expect(card.reload.balances).to include(spendable_cents: 1_000, disputed_cents: 3_000)
  end

  it "pushes hold_released when the nightly reconcile syncs an expired hold" do
    load = stripe_load!(card, 2_000, sender: create(:user), held_until: 1.hour.from_now)
    expect(load.status).to eq("held")
    load.update_columns(held_until: 1.minute.ago)

    Ledger::ReconcileJob.perform_now

    expect(load.reload.status).to eq("available")
    expect(pusher).to have_received(:send_to_user).with(
      recipient, hash_including(title: "Tu saldo ya está disponible", data: hash_including(type: "gift_card_hold_released", load_id: load.id.to_s))
    )
  end

  it "never raises into the caller" do
    load = stripe_load!(card, 2_000, sender: create(:user))
    allow(pusher).to receive(:send_to_user).and_raise("boom")
    expect(described_class.hold_released(load)).to include(success: false)
  end
end

RSpec.describe Loads::RemittanceCounter do
  it "counts Stripe loads by non-Ecuador buyers per calendar year and alerts once at the threshold" do
    ec = create(:user, country_of_residence: "EC")
    us = create(:user, country_of_residence: "US")
    unknown = create(:user, country_of_residence: nil)
    card = create(:gift_card, amount: 0)
    stripe_load!(card, 500, sender: ec)
    stripe_load!(card, 500, sender: us)
    stripe_load!(card, 500, sender: unknown)
    stripe_load!(card, 500, sender: us, at: 13.months.ago)
    card.loads.create!(sender: us, source: :issuance, amount_cents: 100, remaining_cents: 100) # not a purchase

    s = described_class.summary
    expect(s).to include(current_year: 2, prior_year: 1, over_alert: false)

    stub_const("Loads::RemittanceCounter::ALERT_THRESHOLD", 2)
    allow(AdminAlertMailer).to receive(:remittance_threshold).and_return(double(deliver_later: true))
    Rails.cache.clear
    described_class.alert_if_needed!
    described_class.alert_if_needed!
    expect(AdminAlertMailer).to have_received(:remittance_threshold).once.with(hash_including(current_year: 2, over_alert: true))
  end
end
