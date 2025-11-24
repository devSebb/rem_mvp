FactoryBot.define do
  factory :merchant do
    association :user
    store_name { "Demo Store" }
    name { store_name }
    address { "123 Main Street" }
    contact_email { "merchant@example.com" }
    bank_account_iban { "US12345" }
    status { :active }
    sequence(:public_key) { |n| "pub_test_#{n}" }
    sequence(:secret_key_digest) { |n| Merchant.digest_secret("secret#{n}") }
  end
end
