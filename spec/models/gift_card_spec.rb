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
end
