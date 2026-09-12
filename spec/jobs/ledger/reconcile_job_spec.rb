require "rails_helper"

RSpec.describe Ledger::ReconcileJob, type: :job do
  let(:merchant) { create(:merchant) }

  before do
    allow(AdminAlertMailer).to receive(:ledger_drift).and_return(double(deliver_later: true))
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
  end

  it "reports a clean ledger, stores the summary and sends no alert" do
    card = create(:gift_card, merchant: merchant, amount: 0)
    stripe_load!(card, 2_000, sender: create(:user))
    redeem_card!(card, 500, merchant: merchant)

    summary = described_class.perform_now
    expect(summary).to include(cards_checked: 1, drift_count: 0, duplicate_pairs: 0)
    expect(described_class.last_result).to include(drift_count: 0)
    expect(AdminAlertMailer).not_to have_received(:ledger_drift)
  end

  it "syncs stale held statuses once the hold has passed" do
    card = create(:gift_card, merchant: merchant, amount: 0)
    load = stripe_load!(card, 2_000, sender: create(:user), held_until: 1.hour.from_now)
    expect(load.status).to eq("held")

    travel_to(2.hours.from_now) do
      summary = described_class.perform_now
      expect(summary[:statuses_synced]).to eq(1)
    end
    expect(load.reload.status).to eq("available")
  end

  it "detects drift (I1–I9) and alerts the admin team" do
    card = create(:gift_card, merchant: merchant, amount: 0)
    stripe_load!(card, 2_000, sender: create(:user))
    card.update_columns(remaining_balance: 1_999)

    summary = described_class.perform_now
    expect(summary[:drift_count]).to be >= 1 # I1 and I3 both notice
    expect(summary[:drift].first).to include("I1")
    expect(AdminAlertMailer).to have_received(:ledger_drift).with(hash_including(drift_count: summary[:drift_count]))
  end
end
