require "rails_helper"

# Load caps (RELOADABLE_CARD_PLAN.md §3.6 / §4.1).
RSpec.describe PlatformSetting, "load caps", type: :model do
  let(:settings) { described_class.current }

  it "defaults to the launch values" do
    expect(settings.load_caps).to eq(
      max_load_cents: 20_000,
      max_loads_per_card_per_day: 2,
      max_daily_load_per_card_cents: 40_000,
      max_card_balance_cents: 50_000,
      max_daily_load_per_buyer_cents: 60_000,
      max_daily_loads_per_buyer: 3,
      max_30d_load_per_recipient_cents: 100_000,
      max_30d_load_per_buyer_cents: 200_000,
      buyer_refund_window_hours: 72
    )
  end

  it "refuses to exceed any hard ceiling" do
    PlatformSetting::LOAD_CAP_CEILINGS.each do |attr, ceiling|
      expect(settings.update(attr => ceiling + 1)).to be(false), "#{attr} accepted #{ceiling + 1}"
      settings.reload
    end
  end

  it "accepts any value at or below the ceiling" do
    expect(settings.update(max_daily_load_per_card_cents: 200_000, max_card_balance_cents: 200_000)).to be(true)
  end

  it "refuses non-integers, negatives and below-minimum values" do
    expect(settings.update(max_load_cents: 499)).to be(false)
    expect(settings.update(max_loads_per_card_per_day: 0)).to be(false)
    expect(settings.update(buyer_refund_window_hours: -1)).to be(false)
    expect(settings.update(max_load_cents: 1_000.5)).to be(false)
  end

  it "refuses aggregate caps below the single-load cap" do
    expect(settings.update(max_card_balance_cents: 10_000)).to be(false)
    expect(settings.errors[:max_card_balance_cents]).to be_present
    expect(settings.update(max_load_cents: 10_000, max_card_balance_cents: 10_000)).to be(true)
  end
end
