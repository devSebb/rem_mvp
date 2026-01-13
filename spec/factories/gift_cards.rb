FactoryBot.define do
  factory :gift_card do
    sender { association(:user) }
    recipient { association(:user) }
    merchant { association(:merchant) }
    amount { 5000 } # cents
    currency { "USD" }
    status { :active }
    expires_at { 1.year.from_now }
    sequence(:checkout_session_id) { |n| "cs_test_#{n}" }

    trait :without_merchant do
      merchant { nil }
    end
  end
end
