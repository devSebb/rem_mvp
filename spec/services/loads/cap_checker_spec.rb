require "rails_helper"

# §4.1 caps at launch values (PlatformSetting defaults), rolling windows.
RSpec.describe Loads::CapChecker do
  let(:settings) { PlatformSetting.current }
  let(:merchant) { create(:merchant) }
  let(:buyer) { create(:user) }
  let(:recipient) { create(:user) }
  let(:card) { create(:gift_card, recipient: recipient, merchant: merchant, amount: 0) }

  def check!(amount_cents, buyer: self.buyer, recipient: self.recipient, merchant: self.merchant)
    described_class.check!(buyer: buyer, recipient: recipient, merchant: merchant, amount_cents: amount_cents)
  end

  # A Stripe load on `card` (or another card) by `sender`, `at` a point in time.
  def stripe_load!(amount, sender: buyer, on: card, at: Time.current)
    load = create(:gift_card_load, gift_card: on, sender: sender, amount_cents: amount, created_at: at)
    on.update_columns(remaining_balance: on.remaining_balance + amount, total_loaded_cents: on.total_loaded_cents + amount)
    load
  end

  def expect_cap(code, &block)
    expect(&block).to raise_error(described_class::CapExceeded) { |e|
      expect(e.code).to eq(code)
      expect(e.error_code).to eq("checkout.#{code}")
      yield_details(e)
    }
  end

  def yield_details(error)
    expect(error.details).to be_a(Hash)
  end

  it "passes a first $50 load with nothing else around and reports the projected balance" do
    result = check!(5_000)
    expect(result.card).to be_nil
    expect(result.current_balance_cents).to eq(0)
    expect(result.projected_balance_cents).to eq(5_000)
  end

  it "returns the recipient's existing card and projected balance" do
    stripe_load!(3_000)
    result = check!(2_000)
    expect(result.card).to eq(card)
    expect(result.current_balance_cents).to eq(3_000)
    expect(result.projected_balance_cents).to eq(5_000)
  end

  it "rejects amounts outside $5–$200" do
    expect_cap(:load_amount_out_of_range) { check!(499) }
    expect_cap(:load_amount_out_of_range) { check!(20_001) }
    expect { check!(500) }.not_to raise_error
    expect { check!(20_000) }.not_to raise_error
  end

  it "rejects a buyer with an open dispute or an admin block (D4, I13)" do
    buyer.update!(dispute_open_count: 1)
    expect_cap(:buyer_dispute_open) { check!(1_000) }

    buyer.update!(dispute_open_count: 0, purchases_blocked_at: Time.current)
    expect_cap(:buyer_dispute_open) { check!(1_000) }
  end

  describe "per card per 24 h" do
    it "allows 2 loads and refuses the 3rd (count) and $400 (amount)" do
      stripe_load!(10_000, at: 23.hours.ago)
      expect { check!(10_000) }.not_to raise_error

      stripe_load!(10_000, sender: create(:user))
      expect_cap(:card_daily_count_limit) { check!(1_000) }
    end

    it "refuses the load that would exceed $400 on the card today, with the room" do
      stripe_load!(20_000, at: 2.hours.ago)
      settings.update!(max_loads_per_card_per_day: 5)
      expect { check!(20_000) }.not_to raise_error

      stripe_load!(19_000, sender: create(:user), at: 1.hour.ago)
      expect(&-> { check!(2_000) }).to raise_error(described_class::CapExceeded) { |e|
        expect(e.code).to eq(:card_daily_load_limit)
        expect(e.details).to include(limit_cents: 40_000, used_cents: 39_000, room_cents: 1_000)
        expect(e.details[:resets_at]).to be_present
      }
      expect { check!(1_000) }.not_to raise_error
    end

    it "ignores loads older than 24 h" do
      stripe_load!(20_000, at: 25.hours.ago)
      stripe_load!(20_000, sender: create(:user), at: 25.hours.ago)
      settings.update!(max_card_balance_cents: 200_000)
      expect { check!(20_000) }.not_to raise_error
    end
  end

  it "refuses a load that would push the card balance past $500" do
    settings.update!(max_loads_per_card_per_day: 10, max_daily_load_per_card_cents: 200_000,
                     max_daily_load_per_buyer_cents: 200_000, max_daily_loads_per_buyer: 10,
                     max_30d_load_per_recipient_cents: 200_000)
    3.times { |i| stripe_load!(15_000, sender: create(:user), at: (i + 2).days.ago) }
    expect(card.reload.remaining_balance).to eq(45_000)

    expect { check!(5_000) }.not_to raise_error
    expect(&-> { check!(5_001) }).to raise_error(described_class::CapExceeded) { |e|
      expect(e.code).to eq(:card_balance_limit)
      expect(e.details).to include(limit_cents: 50_000, used_cents: 45_000, room_cents: 5_000)
    }
  end

  it "counts spent balance as room again (balance cap looks at remaining, not loaded)" do
    settings.update!(max_loads_per_card_per_day: 10, max_daily_load_per_card_cents: 200_000, max_daily_load_per_buyer_cents: 200_000, max_daily_loads_per_buyer: 10, max_30d_load_per_recipient_cents: 200_000)
    load = stripe_load!(20_000, at: 2.days.ago)
    load.update!(remaining_cents: 0)
    card.update_columns(remaining_balance: 0)
    expect { check!(20_000) }.not_to raise_error
  end

  describe "per buyer per 24 h (all cards)" do
    it "refuses the load past $600 (amount) and the 4th load (count)" do
      settings.update!(max_daily_loads_per_buyer: 10)
      stripe_load!(20_000, on: create(:gift_card, recipient: create(:user), merchant: merchant, amount: 0), at: 3.hours.ago)
      stripe_load!(20_000, on: create(:gift_card, recipient: create(:user), merchant: merchant, amount: 0), at: 2.hours.ago)
      stripe_load!(15_000, on: create(:gift_card, recipient: create(:user), merchant: merchant, amount: 0), at: 1.hour.ago)
      expect(&-> { check!(5_001) }).to raise_error(described_class::CapExceeded) { |e|
        expect(e.code).to eq(:buyer_daily_limit)
        expect(e.details).to include(limit_cents: 60_000, used_cents: 55_000, room_cents: 5_000)
      }
      expect { check!(5_000) }.not_to raise_error

      settings.update!(max_daily_loads_per_buyer: 3)
      expect_cap(:buyer_daily_count_limit) { check!(500) }
    end
  end

  it "refuses a buyer past $2,000 in 30 days" do
    settings.update!(max_daily_loads_per_buyer: 10, max_daily_load_per_buyer_cents: 1_000_000)
    10.times { |i| stripe_load!(20_000, on: create(:gift_card, recipient: create(:user), merchant: merchant, amount: 0), at: (i + 1).days.ago) }
    expect(&-> { check!(500) }).to raise_error(described_class::CapExceeded) { |e|
      expect(e.code).to eq(:buyer_monthly_limit)
      expect(e.details).to include(limit_cents: 200_000, used_cents: 200_000, room_cents: 0)
    }
  end

  it "refuses a recipient past $1,000 in 30 days across senders and merchants" do
    settings.update!(max_card_balance_cents: 200_000, max_daily_load_per_card_cents: 200_000, max_loads_per_card_per_day: 10)
    other_card = create(:gift_card, recipient: recipient, merchant: create(:merchant), amount: 0)
    5.times { |i| stripe_load!(20_000, sender: create(:user), on: i.even? ? card : other_card, at: (i + 1).days.ago) }
    expect(&-> { check!(500) }).to raise_error(described_class::CapExceeded) { |e|
      expect(e.code).to eq(:recipient_monthly_limit)
      expect(e.details).to include(limit_cents: 100_000, used_cents: 100_000, room_cents: 0)
    }
  end

  it "skips recipient and card caps when the recipient is not resolvable yet" do
    expect { check!(20_000, recipient: nil) }.not_to raise_error
  end

  it "does not count admin issuance or adjustment loads toward velocity" do
    create(:gift_card_load, :issuance, gift_card: card, amount_cents: 20_000, created_at: 1.hour.ago)
    create(:gift_card_load, :issuance, gift_card: card, amount_cents: 20_000, created_at: 1.hour.ago)
    card.update_columns(remaining_balance: 40_000, total_loaded_cents: 40_000)
    expect { check!(10_000) }.not_to raise_error
  end
end
