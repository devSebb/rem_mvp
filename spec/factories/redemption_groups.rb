FactoryBot.define do
  factory :redemption_group do
    sequence(:name) { |n| "Grupo #{n}" }
  end
end
