FactoryBot.define do
  factory :gift_card do
    sender { association(:user) }
    recipient { association(:user) }
    merchant { nil }
    amount { 5000 } # cents
    currency { "USD" }
    status { :active }
    expires_at { 1.year.from_now }
    sequence(:checkout_session_id) { |n| "cs_test_#{n}" }
  end
end
