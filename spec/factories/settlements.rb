FactoryBot.define do
  factory :settlement do
    merchant { nil }
    amount { 1 }
    payout_status { 1 }
    period_start { "2025-09-28" }
    period_end { "2025-09-28" }
    # Exact window (Settlement#period_range). Fixtures cover their whole days;
    # real payouts use the creation time as the cutoff.
    period_start_at { period_start.to_date.beginning_of_day }
    period_end_at { period_end.to_date.end_of_day }
    notes { "MyText" }
  end
end
