require 'rails_helper'

RSpec.describe Merchant, type: :model do
  describe "#effective_coverage_text" do
    it "returns nil for direct-redemption merchants with no coverage text" do
      merchant = build(:merchant)

      expect(merchant.effective_coverage_text).to be_nil
    end

    it "returns custom coverage text verbatim when present" do
      merchant = build(:merchant, coverage_text: "  Canjeable en 3 locales en Quito. ")

      expect(merchant.effective_coverage_text).to eq("Canjeable en 3 locales en Quito.")
    end

    it "falls back to the partner disclaimer for partner-routed merchants" do
      merchant = build(:merchant, partner_redemption: true)

      expect(merchant.effective_coverage_text)
        .to eq("Para canjear esta tarjeta, paga en Medicity o Farmacias Económicas.")
    end

    it "uses a custom partner label in the fallback disclaimer" do
      merchant = build(:merchant, partner_redemption: true, redemption_partner_label: "Medicity")

      expect(merchant.effective_coverage_text).to eq("Para canjear esta tarjeta, paga en Medicity.")
    end

    it "prefers custom coverage text over the partner disclaimer" do
      merchant = build(:merchant, partner_redemption: true, coverage_text: "Texto propio.")

      expect(merchant.effective_coverage_text).to eq("Texto propio.")
    end
  end
end
