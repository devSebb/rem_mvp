namespace :stripe do
  # Replays every Stripe refund through the same reconciliation path the
  # refund.* webhooks use (StripeWebhooks.handle_refund_event). Fully
  # idempotent: already-recorded refunds are skipped via the
  # stripe_refund_id de-dupe, so this is safe to run any number of times.
  #
  # Use cases:
  #   - Backfill refunds issued before the refund.* webhook handlers
  #     existed (e.g. the 2026-05-28 dashboard refund).
  #   - Repair after a webhook outage or misconfiguration.
  #
  #   bundle exec rails stripe:reconcile_refunds
  desc "Reconcile all Stripe refunds against the internal ledger (idempotent)"
  task reconcile_refunds: :environment do
    processed = 0
    reconciled = 0

    Stripe::Refund.list({ limit: 100 }).auto_paging_each do |refund|
      processed += 1
      already_recorded = Transaction.refunds
                                    .where("metadata->>'stripe_refund_id' = ?", refund.id)
                                    .exists?

      StripeWebhooks.handle_refund_event(refund)

      unless already_recorded
        now_recorded = Transaction.refunds
                                  .where("metadata->>'stripe_refund_id' = ?", refund.id)
                                  .exists?
        if now_recorded
          reconciled += 1
          puts "RECONCILED #{refund.id} (#{refund.amount} #{refund.currency}, PI: #{refund.payment_intent})"
        else
          puts "SKIPPED    #{refund.id} (no matching gift card — likely an orphaned-payment auto-refund)"
        end
      end
    end

    puts "Done. #{processed} Stripe refunds checked, #{reconciled} newly reconciled."
  end
end
