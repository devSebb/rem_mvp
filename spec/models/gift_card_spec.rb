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
  end
end
