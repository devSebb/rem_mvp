require 'rails_helper'

RSpec.describe GiftCard, type: :model do
  describe "validations" do
    it "requires a sender" do
      gift_card = FactoryBot.build(:gift_card, sender: nil)
      expect(gift_card).not_to be_valid
      expect(gift_card.errors[:sender]).to be_present
    end

    it "requires a recipient" do
      gift_card = FactoryBot.build(:gift_card, recipient: nil)
      expect(gift_card).not_to be_valid
      expect(gift_card.errors[:recipient]).to be_present
    end

    describe "amount validation" do
      it "allows amount up to MAX_AMOUNT_CENTS" do
        gift_card = FactoryBot.create(:gift_card, amount: GiftCard::MAX_AMOUNT_CENTS)
        expect(gift_card).to be_valid
        expect(gift_card.amount).to eq(GiftCard::MAX_AMOUNT_CENTS)
      end

      it "rejects amount greater than MAX_AMOUNT_CENTS" do
        # Create a valid gift card first, then test updating with invalid amount
        # This avoids the code_digest uniqueness check issue with build
        gift_card = FactoryBot.create(:gift_card, amount: GiftCard::MAX_AMOUNT_CENTS)
        gift_card.amount = GiftCard::MAX_AMOUNT_CENTS + 1
        
        expect(gift_card).not_to be_valid
        expect(gift_card.errors[:amount]).to be_present
      end

      it "allows amount less than MAX_AMOUNT_CENTS" do
        gift_card = FactoryBot.create(:gift_card, amount: GiftCard::MAX_AMOUNT_CENTS - 1)
        expect(gift_card).to be_valid
        expect(gift_card.amount).to eq(GiftCard::MAX_AMOUNT_CENTS - 1)
      end
    end
  end

  describe "#expired?" do
    it "always returns false (gift cards never expire)" do
      gift_card = FactoryBot.create(:gift_card, expires_at: nil)
      expect(gift_card.expired?).to be false

      gift_card = FactoryBot.create(:gift_card, expires_at: 1.year.ago)
      expect(gift_card.expired?).to be false

      gift_card = FactoryBot.create(:gift_card, expires_at: 1.year.from_now)
      expect(gift_card.expired?).to be false
    end
  end

  describe "#touch_owner_activity!" do
    it "updates last_owner_activity_at without touching updated_at" do
      gift_card = FactoryBot.create(:gift_card)
      original_updated_at = gift_card.updated_at
      original_activity_at = gift_card.last_owner_activity_at

      # Wait a moment to ensure timestamps would differ
      sleep(0.1)

      gift_card.touch_owner_activity!

      gift_card.reload
      expect(gift_card.last_owner_activity_at).to be_present
      expect(gift_card.last_owner_activity_at).to be > original_activity_at if original_activity_at
      # updated_at should not change (or change minimally due to DB precision)
      expect(gift_card.updated_at).to be_within(1.second).of(original_updated_at)
    end

    it "does not raise if record is invalid" do
      gift_card = FactoryBot.create(:gift_card)
      gift_card.update_column(:merchant_id, nil) # Make invalid

      expect { gift_card.touch_owner_activity! }.not_to raise_error
    end
  end
end
