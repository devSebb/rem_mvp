require "rails_helper"

RSpec.describe PlatformSetting, type: :model do
  describe ".current" do
    it "creates the single settings row with zero fees on first access" do
      expect { described_class.current }.to change(described_class, :count).from(0).to(1)

      settings = described_class.current
      expect(settings.buyer_fee_bps).to eq(0)
      expect(settings.buyer_fee_fixed_cents).to eq(0)
      expect(settings.merchant_commission_bps).to eq(0)
      expect(settings.purchases_enabled).to be(true)
    end

    it "reuses the existing row" do
      existing = described_class.current

      expect(described_class.current.id).to eq(existing.id)
      expect(described_class.count).to eq(1)
    end
  end

  describe "validations" do
    it "rejects negative and over-ceiling values" do
      settings = described_class.current

      expect(settings.update(buyer_fee_bps: -1)).to be(false)
      expect(settings.update(buyer_fee_bps: PlatformSetting::MAX_BPS + 1)).to be(false)
      expect(settings.update(buyer_fee_fixed_cents: PlatformSetting::MAX_FIXED_CENTS + 1)).to be(false)
      expect(settings.update(merchant_commission_bps: PlatformSetting::MAX_BPS + 1)).to be(false)
      expect(settings.update(buyer_fee_bps: 250, buyer_fee_fixed_cents: 30, merchant_commission_bps: 500)).to be(true)
    end
  end

  describe "#buyer_fee_cents_for" do
    it "returns 0 with launch pricing" do
      expect(described_class.current.buyer_fee_cents_for(5_000)).to eq(0)
    end

    it "combines percentage (rounded) and fixed components" do
      settings = described_class.current
      settings.update!(buyer_fee_bps: 250, buyer_fee_fixed_cents: 30)

      # 2.5% of $25.00 = 62.5 → 63, + 30 fixed
      expect(settings.buyer_fee_cents_for(2_500)).to eq(93)
      # 2.5% of $50.00 = 125, + 30 fixed
      expect(settings.buyer_fee_cents_for(5_000)).to eq(155)
    end
  end

  describe "#merchant_commission_cents_for" do
    it "returns 0 with launch pricing" do
      expect(described_class.current.merchant_commission_cents_for(10_000)).to eq(0)
    end

    it "applies the commission rate rounded to the cent" do
      settings = described_class.current
      settings.update!(merchant_commission_bps: 500)

      expect(settings.merchant_commission_cents_for(10_000)).to eq(500)
      expect(settings.merchant_commission_cents_for(1_010)).to eq(51) # 50.5 → 51
    end
  end
end
