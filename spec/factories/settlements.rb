FactoryBot.define do
  factory :settlement do
    merchant { nil }
    amount { 1 }
    payout_status { 1 }
    period_start { "2025-09-28" }
    period_end { "2025-09-28" }
    notes { "MyText" }
  end
end
