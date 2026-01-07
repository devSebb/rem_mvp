FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "user#{n}@example.com" }
    password { "password123" }
    name { "Test User" }
    role { :user }
    sequence(:national_id) { |n| "ABC12#{format('%02d', n)}" } # >= 7 alphanumeric chars
  end
end
