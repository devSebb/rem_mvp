# Nightly ledger reconciliation (RELOADABLE_CARD_PLAN.md §4.6, §12.4).
# Runs Ledger::Verifier over every card, refreshes stale time-derived load
# statuses (a hold that expired since the last write), records the result
# for the admin dashboard and emails the admin team on any drift.
#
# Schedule: no in-process scheduler exists (plain Sidekiq). Run nightly via
# `bin/rake ledger:reconcile` from a Render cron job, or enqueue
# `Ledger::ReconcileJob.perform_later` from wherever cron lives.
module Ledger
  class ReconcileJob < ApplicationJob
    queue_as :default

    LAST_RESULT_KEY = "ledger:reconcile:last_result".freeze

    def perform
      synced = sync_stale_load_statuses
      result = Ledger::Verifier.call
      summary = {
        ran_at: Time.current.iso8601,
        cards_checked: result.cards_checked,
        drift_count: result.drift.size,
        warning_count: result.warnings.size,
        info_count: result.info.size,
        duplicate_pairs: result.duplicate_pairs.size,
        statuses_synced: synced,
        drift: result.drift.first(50)
      }

      Rails.cache.write(LAST_RESULT_KEY, summary, expires_in: 8.days)
      Rails.logger.info "[Ledger::ReconcileJob] #{summary.except(:drift).inspect}"

      if result.drift.any? || result.duplicate_pairs.any?
        AdminAlertMailer.ledger_drift(summary).deliver_later
      end

      # §4.5: remittance-rule counter, alert at 400 (once per year).
      begin
        Loads::RemittanceCounter.alert_if_needed!
      rescue => e
        Rails.logger.error "[Ledger::ReconcileJob] remittance counter failed: #{e.class} - #{e.message}"
      end

      summary
    end

    def self.last_result
      Rails.cache.read(LAST_RESULT_KEY)
    end

    private

    # Status is derived at write time; a hold expiring is not a write. Bring
    # the cached column back in line so admin filters stay truthful, and
    # tell the recipient their funds are spendable (§4.4 "hold released").
    def sync_stale_load_statuses
      synced = 0
      GiftCardLoad.where(status: :held).where("held_until IS NULL OR held_until <= ?", Time.current).find_each do |load|
        new_status = load.sync_status!
        Messaging::LoadEventPusher.hold_released(load) if new_status == :available
        synced += 1
      end
      synced
    end
  end
end
