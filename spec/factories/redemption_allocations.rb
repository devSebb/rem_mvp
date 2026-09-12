FactoryBot.define do
  factory :redemption_allocation do
    gift_card_load { association(:gift_card_load) }
    ledger_transaction do
      association(:transaction,
                  gift_card: gift_card_load.gift_card,
                  merchant: gift_card_load.gift_card.merchant,
                  txn_type: :redemption,
                  status: :succeeded,
                  amount: amount_cents,
                  currency: "USD")
    end
    amount_cents { 1000 }
    direction { :debit }

    trait :credit do
      direction { :credit }
    end
  end
end
