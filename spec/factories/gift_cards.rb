FactoryBot.define do
  factory :gift_card do
    sender { nil }
    recipient { nil }
    merchant { nil }
    amount { 1 }
    currency { "MyString" }
    code_digest { "MyString" }
    status { 1 }
    redeemed_at { "2025-09-28 22:12:19" }
    expires_at { "2025-09-28 22:12:19" }
    checkout_session_id { "MyString" }
  end
end
