# Ledger integrity tooling for the reloadable-card model
# (RELOADABLE_CARD_PLAN.md §7, §10 Phase 1 step 4, §12.4).
namespace :ledger do
  desc "Assert §7 ledger invariants on every gift card. Exits 1 on drift. VERBOSE=1 prints warnings/info lines."
  task verify: :environment do
    result = Ledger::Verifier.call
    verbose = ENV["VERBOSE"].to_s == "1"

    puts "🔎 ledger:verify — #{result.cards_checked} cards checked"
    puts "   drift:    #{result.drift.size}"
    puts "   warnings: #{result.warnings.size}"
    puts "   info:     #{result.info.size}"
    puts "   duplicate (recipient, merchant) pairs (I12, resolved by Phase 2 merge): #{result.duplicate_pairs.size}"

    result.drift.each { |line| puts "   ❌ #{line}" }
    if verbose
      result.warnings.each { |line| puts "   ⚠️  #{line}" }
      result.info.each { |line| puts "   ℹ️  #{line}" }
      result.duplicate_pairs.each { |(recipient_id, merchant_id), n| puts "   ↔  recipient #{recipient_id} × merchant #{merchant_id}: #{n} cards" }
    elsif result.warnings.any? || result.info.any?
      puts "   (re-run with VERBOSE=1 to list warnings and info)"
    end

    if result.ok?
      puts "✅ OK — 0 drift"
    else
      puts "💥 DRIFT DETECTED — do not proceed (§16.5)"
      exit 1
    end
  end

  desc "Nightly reconcile (§4.6): sync stale load statuses, verify, alert on drift. Wire to a Render cron job."
  task reconcile: :environment do
    summary = Ledger::ReconcileJob.perform_now
    puts "🔎 ledger:reconcile — #{summary[:cards_checked]} cards, drift #{summary[:drift_count]}, " \
         "warnings #{summary[:warning_count]}, statuses synced #{summary[:statuses_synced]}"
    summary[:drift].each { |line| puts "   ❌ #{line}" }
    exit 1 if summary[:drift_count].positive?
  end

  desc "Create the single legacy load (+ allocations, txn links) for any gift card that has none. Idempotent."
  task backfill_missing_loads: :environment do
    missing = GiftCard.where(merged_into_id: nil).where.missing(:loads).count
    puts "🔄 #{missing} gift card(s) without loads"
    next if missing.zero?

    result = Ledger::LegacyLoadBackfill.call
    puts "✅ cards: #{result[:cards]}, loads: #{result[:loads]}, allocations: #{result[:allocations]}, " \
         "txns linked: #{result[:transactions_linked]}, statuses remapped: #{result[:statuses_remapped]}"
    puts "   Now run: bin/rake ledger:verify"
  end
end
