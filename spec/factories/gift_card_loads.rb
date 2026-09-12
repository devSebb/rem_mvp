FactoryBot.define do
  factory :gift_card_load do
    gift_card { association(:gift_card) }
    sender { association(:user) }
    source { :stripe }
    sequence(:payment_intent_id) { |n| "pi_test_load_#{n}" }
    amount_cents { 5000 }
    remaining_cents { amount_cents }
    currency { "USD" }
    fee_cents { 0 }

    trait :issuance do
      source { :issuance }
      payment_intent_id { nil }
      sender { nil }
    end

    trait :held do
      held_until { 24.hours.from_now }
      risk_score { 70 }
      risk_level { "elevated" }
    end

    trait :disputed do
      disputed_at { Time.current }
      sequence(:dispute_id) { |n| "dp_test_#{n}" }
    end

    trait :dispute_lost do
      disputed_at { 1.day.ago }
      sequence(:dispute_id) { |n| "dp_test_lost_#{n}" }
      dispute_outcome { "lost" }
      remaining_cents { 0 }
      written_off_cents { amount_cents }
    end

    trait :refunded do
      remaining_cents { 0 }
      refunded_cents { amount_cents }
    end

    trait :exhausted do
      remaining_cents { 0 }
    end
  end
end
