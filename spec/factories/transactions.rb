FactoryBot.define do
  factory :transaction do
    gift_card { nil }
    amount { 1 }
    txn_type { 1 }
    status { 1 }
    sequence(:processor_ref) { |n| "txn_ref_#{n}" }
    currency { "USD" }
    metadata { {} }
  end
end
