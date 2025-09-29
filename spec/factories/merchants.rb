FactoryBot.define do
  factory :merchant do
    user { nil }
    store_name { "MyString" }
    address { "MyText" }
    contact_email { "MyString" }
    bank_account_iban { "MyString" }
  end
end
