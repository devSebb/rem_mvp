require 'rails_helper'

RSpec.describe User, type: :model do
  describe "validations" do
    it "requires first_name and last_name" do
      user = FactoryBot.build(:user, first_name: nil, last_name: nil)

      expect(user).not_to be_valid
      expect(user.errors[:first_name]).to be_present
      expect(user.errors[:last_name]).to be_present
    end

    it "requires phone" do
      user = FactoryBot.build(:user, phone: nil)

      expect(user).not_to be_valid
      expect(user.errors[:phone]).to be_present
    end

    it "derives name from first and last name" do
      user = FactoryBot.build(:user, name: nil, first_name: "Jane", last_name: "Doe")

      expect(user).to be_valid
      user.validate
      expect(user.name).to eq("Jane Doe")
    end

    it "splits legacy name when first/last are missing" do
      user = FactoryBot.build(:user, first_name: nil, last_name: nil, name: "Jane Smith")

      expect(user).to be_valid
      expect(user.first_name).to eq("Jane")
      expect(user.last_name).to eq("Smith")
    end

    it "normalizes national_id by stripping spaces/dashes and uppercasing when provided" do
      user = FactoryBot.build(:user, national_id: " ab- c12 34 ")

      expect(user).to be_valid
      user.validate
      expect(user.national_id).to eq("ABC1234")
    end

    it "does not require KYC fields by default" do
      user = FactoryBot.build(:user, address: nil, country_of_residence: nil, date_of_birth: nil)

      expect(user).to be_valid
    end
  end

  describe "checkout KYC validations" do
    it "requires address, country_of_residence, and date_of_birth on checkout context" do
      user = FactoryBot.build(:user, address: nil, country_of_residence: nil, date_of_birth: nil)

      expect(user).not_to be_valid(:checkout_kyc)
      expect(user.errors[:address]).to be_present
      expect(user.errors[:country_of_residence]).to be_present
      expect(user.errors[:date_of_birth]).to be_present
    end

    it "passes checkout context when KYC fields are filled" do
      user = FactoryBot.build(:user, address: "123 Main St", country_of_residence: "PE", date_of_birth: Date.new(1990, 1, 1))

      expect(user).to be_valid(:checkout_kyc)
    end
  end
end
