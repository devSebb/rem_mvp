require 'rails_helper'

RSpec.describe User, type: :model do
  describe "validations" do
    it "requires national_id on create" do
      user = FactoryBot.build(:user, national_id: nil)
      expect(user).not_to be_valid
      expect(user.errors[:national_id]).to be_present
    end

    it "requires national_id to be at least 7 alphanumeric characters" do
      user = FactoryBot.build(:user, national_id: "ABC123")
      expect(user).not_to be_valid
      expect(user.errors[:national_id]).to be_present
    end

    it "normalizes national_id by stripping spaces/dashes and uppercasing" do
      user = FactoryBot.build(:user, national_id: " ab- c12 34 ")
      expect(user).to be_valid
      user.validate
      expect(user.national_id).to eq("ABC1234")
    end
  end
end
