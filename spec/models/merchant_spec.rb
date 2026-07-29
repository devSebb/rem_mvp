require 'rails_helper'

RSpec.describe Merchant, type: :model do
  # `name` is a legacy duplicate of `store_name` still exposed by the merchant
  # API. It used to be written only once, so renaming a store left the old name
  # behind for anything reading it.
  describe "display name mirroring" do
    it "copies store_name into name on create" do
      merchant = create(:merchant, store_name: "Farmacia Buendía", name: nil)

      expect(merchant.name).to eq("Farmacia Buendía")
    end

    it "keeps name in sync when the store is renamed" do
      merchant = create(:merchant, store_name: "Farmacia Buendía")

      merchant.update!(store_name: "Medicity")

      expect(merchant.reload.name).to eq("Medicity")
    end

    it "leaves name untouched when store_name is blank" do
      merchant = create(:merchant, store_name: "Medicity")

      merchant.store_name = ""

      expect(merchant).not_to be_valid
      expect(merchant.name).to eq("Medicity")
    end
  end

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
