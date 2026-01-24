FactoryBot.define do
  factory :gift_card do
    sender { association(:user) }
    recipient { association(:user) }
    merchant { association(:merchant) }
    amount { 5000 } # cents
    currency { "USD" }
    status { :active }
    expires_at { nil } # Gift cards never expire
    sequence(:checkout_session_id) { |n| "cs_test_#{n}" }
    note { nil }

    trait :without_merchant do
      merchant { nil }
    end

    trait :with_note do
      note { "Happy birthday! Enjoy your gift." }
    end
  end
end
