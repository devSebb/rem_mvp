require "rails_helper"

RSpec.describe MoneyInput do
  it "converts typed amounts to exact cents (no Float truncation)" do
    expect(described_class.to_cents("19.99")).to eq(1_999) # Float path gave 1998
    expect(described_class.to_cents("0.29")).to eq(29)     # Float path gave 28
    expect(described_class.to_cents("4.35")).to eq(435)    # Float path gave 434
    expect(described_class.to_cents("10")).to eq(1_000)
    expect(described_class.to_cents("10.5")).to eq(1_050)
    expect(described_class.to_cents(" $7.10 ")).to eq(710)
  end

  it "accepts a decimal comma (es-EC keyboards)" do
    expect(described_class.to_cents("19,99")).to eq(1_999)
  end

  it "every cent value from 0.00 to 99.99 round-trips exactly" do
    (0..9_999).each do |cents|
      text = format("%d.%02d", cents / 100, cents % 100)
      expect(described_class.to_cents(text)).to eq(cents), "#{text} -> #{described_class.to_cents(text)}"
    end
  end

  it "rejects anything that isn't a plain amount with at most two decimals" do
    [ nil, "", "abc", "-5", "1.999", "1,234.50", "1.2.3", "5$", "1e3" ].each do |bad|
      expect(described_class.to_cents(bad)).to be_nil, "#{bad.inspect} should be rejected"
    end
  end
end
