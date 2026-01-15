require 'rails_helper'

RSpec.describe GiftCardPurchaseLimiter do
  let(:user) { create(:user) }
  let(:merchant) { create(:merchant) }

  describe ".can_purchase?" do
    context "when user has no purchases" do
      it "allows purchase" do
        result = described_class.can_purchase?(user: user)
        expect(result[:allowed]).to be true
        expect(result[:count]).to eq(0)
        expect(result[:limit]).to eq(5)
        expect(result[:reason]).to be_nil
      end
    end

    context "when user has purchases under limit" do
      before do
        3.times do
          create(:gift_card, sender: user, merchant: merchant, created_at: 1.hour.ago)
        end
      end

      it "allows purchase" do
        result = described_class.can_purchase?(user: user)
        expect(result[:allowed]).to be true
        expect(result[:count]).to eq(3)
        expect(result[:limit]).to eq(5)
      end
    end

    context "when user has reached limit" do
      before do
        5.times do
          create(:gift_card, sender: user, merchant: merchant, created_at: 1.hour.ago)
        end
      end

      it "rejects purchase" do
        result = described_class.can_purchase?(user: user)
        expect(result[:allowed]).to be false
        expect(result[:count]).to eq(5)
        expect(result[:limit]).to eq(5)
        expect(result[:reason]).to include("Maximum of 5")
        expect(result[:reason]).to include("24 hours")
      end
    end

    context "when user has purchases older than 24 hours" do
      before do
        5.times do
          create(:gift_card, sender: user, merchant: merchant, created_at: 25.hours.ago)
        end
      end

      it "allows purchase" do
        result = described_class.can_purchase?(user: user)
        expect(result[:allowed]).to be true
        expect(result[:count]).to eq(0)
      end
    end

    context "when user has mix of old and new purchases" do
      before do
        3.times do
          create(:gift_card, sender: user, merchant: merchant, created_at: 25.hours.ago)
        end
        2.times do
          create(:gift_card, sender: user, merchant: merchant, created_at: 1.hour.ago)
        end
      end

      it "only counts purchases in last 24 hours" do
        result = described_class.can_purchase?(user: user)
        expect(result[:allowed]).to be true
        expect(result[:count]).to eq(2)
      end
    end

    context "when user has canceled gift cards" do
      before do
        3.times do
          create(:gift_card, sender: user, merchant: merchant, created_at: 1.hour.ago, status: :canceled)
        end
        2.times do
          create(:gift_card, sender: user, merchant: merchant, created_at: 1.hour.ago, status: :active)
        end
      end

      it "does not count canceled cards" do
        result = described_class.can_purchase?(user: user)
        expect(result[:allowed]).to be true
        expect(result[:count]).to eq(2)
      end
    end

    context "when user is nil" do
      it "rejects purchase" do
        result = described_class.can_purchase?(user: nil)
        expect(result[:allowed]).to be false
        expect(result[:reason]).to include("User is required")
      end
    end
  end

  describe ".purchases_in_last_24h" do
    it "returns 0 when user has no purchases" do
      expect(described_class.purchases_in_last_24h(user: user)).to eq(0)
    end

    it "returns correct count for purchases in last 24 hours" do
      3.times do
        create(:gift_card, sender: user, merchant: merchant, created_at: 1.hour.ago)
      end
      2.times do
        create(:gift_card, sender: user, merchant: merchant, created_at: 25.hours.ago)
      end

      expect(described_class.purchases_in_last_24h(user: user)).to eq(3)
    end

    it "returns 0 when user is nil" do
      expect(described_class.purchases_in_last_24h(user: nil)).to eq(0)
    end
  end
end

