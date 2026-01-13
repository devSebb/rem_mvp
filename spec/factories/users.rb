FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "user#{n}@example.com" }
    password { "password123" }
    sequence(:first_name) { |n| "Test#{n}" }
    sequence(:last_name) { |n| "User#{n}" }
    sequence(:phone) { |n| "+1555000#{format('%04d', n)}" }
    name { "#{first_name} #{last_name}" }
    role { :user }
  end
end
