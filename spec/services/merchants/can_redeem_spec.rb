require "rails_helper"

RSpec.describe Merchants::CanRedeem do
  let(:group) { create(:redemption_group, name: "Farmaenlace") }
  let(:issuer) { create(:merchant, redemption_group: group) }
  let(:peer) { create(:merchant, redemption_group: group) }
  let(:outsider) { create(:merchant) }
  let(:other_group_merchant) { create(:merchant, redemption_group: create(:redemption_group)) }

  it "lets a merchant redeem its own cards" do
    expect(described_class.call(redeemer: issuer, issuer: issuer)).to be(true)
    expect(described_class.call(redeemer: outsider, issuer: outsider)).to be(true)
  end

  it "lets merchants in the same group redeem each other's cards (D6)" do
    expect(described_class.call(redeemer: peer, issuer: issuer)).to be(true)
    expect(described_class.call(redeemer: issuer, issuer: peer)).to be(true)
  end

  it "refuses a merchant outside the issuer's group" do
    expect(described_class.call(redeemer: outsider, issuer: issuer)).to be(false)
    expect(described_class.call(redeemer: other_group_merchant, issuer: issuer)).to be(false)
  end

  it "refuses when the issuer has no group, even if the redeemer has one" do
    expect(described_class.call(redeemer: peer, issuer: outsider)).to be(false)
  end

  it "refuses nil parties" do
    expect(described_class.call(redeemer: nil, issuer: issuer)).to be(false)
    expect(described_class.call(redeemer: issuer, issuer: nil)).to be(false)
  end
end
