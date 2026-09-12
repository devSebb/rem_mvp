module Loads
  # §4.5 remittance-rule counter. Each Stripe-funded load paid by a buyer
  # whose country of residence is not Ecuador is a potential CFPB "remittance
  # transfer" (12 CFR 1005.30); the safe harbor is ≤ 500 in the prior AND the
  # current calendar year. Counsel decision required before 500; the admin
  # team is alerted at ALERT_THRESHOLD.
  module RemittanceCounter
    SAFE_HARBOR = 500
    ALERT_THRESHOLD = 400
    ALERT_CACHE_KEY = "loads:remittance_alert:%d".freeze

    module_function

    def count_for_year(year)
      from = Time.zone.local(year, 1, 1)
      GiftCardLoad.in_scope.source_stripe
                  .joins(:sender)
                  .where(created_at: from...(from + 1.year))
                  .where("users.country_of_residence IS NULL OR UPPER(users.country_of_residence) <> 'EC'")
                  .count
    end

    def summary(now: Time.current)
      year = now.year
      current = count_for_year(year)
      prior = count_for_year(year - 1)
      {
        year: year,
        current_year: current,
        prior_year: prior,
        safe_harbor: SAFE_HARBOR,
        alert_threshold: ALERT_THRESHOLD,
        over_alert: current >= ALERT_THRESHOLD || prior >= ALERT_THRESHOLD
      }
    end

    # Emails the admin team once per calendar year when the count crosses
    # ALERT_THRESHOLD. Called by Ledger::ReconcileJob nightly.
    def alert_if_needed!(now: Time.current)
      s = summary(now: now)
      return s unless s[:over_alert]

      if Rails.cache.write(format(ALERT_CACHE_KEY, s[:year]), true, unless_exist: true, expires_in: 400.days)
        AdminAlertMailer.remittance_threshold(s).deliver_later
      end
      s
    end
  end
end
