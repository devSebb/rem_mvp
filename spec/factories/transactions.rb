FactoryBot.define do
  factory :transaction do
    gift_card { nil }
    amount { 1 }
    txn_type { 1 }
    status { 1 }
    processor_ref { "MyString" }
    metadata { "" }
  end
end
