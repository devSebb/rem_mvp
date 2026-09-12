# Asserts the ledger invariants of RELOADABLE_CARD_PLAN.md §7 over gift
# cards, loads, allocations and transactions. Used by `rake ledger:verify`
# (ad hoc, Phase 1+), by GiftCard#verify_ledger! in specs, and by
# Ledger::ReconcileJob (Phase 3, nightly).
#
# Three severities:
#   drift    — an invariant is broken; money is unaccounted for. Stop.
#   warning  — explainable by legacy behaviour and safe to proceed on, but
#              listed so a human sees it (e.g. a card canceled by the old
#              `gift_cards:cancel_fakes` task, which zeroed balances without
#              writing a ledger row; a load whose cached status lags the
#              time-based hold expiry).
#   info     — legacy loads with no purchase/issuance ledger row at all
#              (cards minted before the ledger existed). Nothing to fix.
module Ledger
  class Verifier
    class DriftError < StandardError; end

    CardReport = Struct.new(:card_id, :status, :drift, :warnings, :info, keyword_init: true) do
      def clean? = drift.empty?
    end

    Result = Struct.new(:cards_checked, :reports, :duplicate_pairs, keyword_init: true) do
      def drift = reports.flat_map { |r| r.drift.map { |d| "card #{r.card_id} (#{r.status}): #{d}" } }
      def warnings = reports.flat_map { |r| r.warnings.map { |w| "card #{r.card_id} (#{r.status}): #{w}" } }
      def info = reports.flat_map { |r| r.info.map { |i| "card #{r.card_id} (#{r.status}): #{i}" } }
      def ok? = drift.empty?
    end

    # ── Public API ──────────────────────────────────────────────────────

    # Drift strings only (what specs assert against).
    def self.card_drift(card)
      card_report(card).drift
    end

    def self.card_report(card)
      new.card_report(card)
    end

    # @param scope [ActiveRecord::Relation<GiftCard>]
    def self.call(scope: GiftCard.all)
      verifier = new
      reports = []
      scope.includes(:loads).find_each(batch_size: 200) do |card|
        report = verifier.card_report(card)
        reports << report if report.drift.any? || report.warnings.any? || report.info.any?
      end
      Result.new(
        cards_checked: scope.count,
        reports: reports,
        duplicate_pairs: duplicate_pairs(scope)
      )
    end

    # I12 (informational until the Phase 2 unique index exists): non-merged
    # cards sharing a (recipient, merchant) pair.
    def self.duplicate_pairs(scope)
      scope.where(merged_into_id: nil)
           .group(:recipient_id, :merchant_id)
           .having("COUNT(*) > 1")
           .count
    end

    # ── Per-card checks ─────────────────────────────────────────────────

    def card_report(card)
      drift = []
      warnings = []
      info = []

      loads = GiftCardLoad.where(gift_card_id: card.id).fifo.to_a
      if loads.empty?
        drift << "no loads (run `rake ledger:backfill_missing_loads`)"
        return CardReport.new(card_id: card.id, status: card.status, drift: drift, warnings: warnings, info: info)
      end

      in_scope = loads.reject(&:status_canceled?)
      allocs = allocation_sums(loads.map(&:id))
      txns = Transaction.where(gift_card_id: card.id).to_a
      succeeded = txns.select(&:succeeded?)

      # I1 — cached card balance equals the sum of its loads.
      sum_remaining = in_scope.sum(&:remaining_cents)
      if card.remaining_balance.to_i != sum_remaining
        drift << "I1 remaining_balance #{card.remaining_balance.to_i} != Σ loads.remaining_cents #{sum_remaining}"
      end

      sum_amount = in_scope.sum(&:amount_cents)
      if card.total_loaded_cents.to_i != sum_amount
        drift << "total_loaded_cents #{card.total_loaded_cents.to_i} != Σ loads.amount_cents #{sum_amount}"
      end

      if card.loads_count.to_i != loads.size
        drift << "loads_count #{card.loads_count.to_i} != #{loads.size} loads"
      end

      # I9 — status vocabulary.
      drift << "I9 status is legacy `#{card.status}`" if card.redeemed? || card.expired?
      drift << "I9 frozen without frozen_at" if card.frozen_by_admin? && card.frozen_at.nil?
      drift << "I9 frozen_at set on non-frozen card" if !card.frozen_by_admin? && card.frozen_at.present?

      # I2 — per load.
      loads.each do |load|
        debit = allocs.dig(load.id, "debit").to_i
        credit = allocs.dig(load.id, "credit").to_i
        label = "load #{load.id}"

        if load.remaining_cents.negative? || load.remaining_cents > load.amount_cents
          drift << "I2 #{label} remaining_cents #{load.remaining_cents} outside 0..#{load.amount_cents}"
        end
        if load.refunded_cents.negative? || load.written_off_cents.negative?
          drift << "I2 #{label} negative refunded/written_off"
        end

        lhs = load.remaining_cents + load.refunded_cents + load.written_off_cents + debit - credit
        if lhs != load.amount_cents
          msg = "I2 #{label} remaining #{load.remaining_cents} + refunded #{load.refunded_cents} + " \
                "written_off #{load.written_off_cents} + debits #{debit} − credits #{credit} = #{lhs} != amount #{load.amount_cents}"
          if card.canceled? && !load.status_canceled?
            warnings << "legacy canceled card, balance voided without a ledger row: #{msg}"
          else
            drift << msg
          end
        end

        unless load.status_in_sync?
          warnings << "#{label} status `#{load.status}` stale, derived `#{load.derived_status}`"
        end

        # §4.6 ledger ↔ load column cross-checks (per load, via gift_card_load_id).
        load_txns = succeeded.select { |t| t.gift_card_load_id == load.id }
        funded = load_txns.select { |t| t.purchase? || t.issuance? }.sum(&:amount)
        if funded.zero?
          info << "#{label} has no purchase/issuance ledger row (pre-ledger legacy card)"
        elsif funded != load.amount_cents
          drift << "#{label} Σ purchase+issuance txns #{funded} != amount_cents #{load.amount_cents}"
        end

        refunded = load_txns.select { |t| t.refund? && t.reversal_of_transaction_id.nil? }.sum(&:amount)
        if refunded != load.refunded_cents
          drift << "#{label} Σ Stripe refund txns #{refunded} != refunded_cents #{load.refunded_cents}"
        end

        written_off = load_txns.select { |t| t.adjustment? && t.processor_ref.to_s.start_with?("dispute_") }.sum(&:amount)
        if written_off != load.written_off_cents
          drift << "#{label} Σ dispute write-off txns #{written_off} != written_off_cents #{load.written_off_cents}"
        end
      end

      # I3 — card-level ledger equation.
      redeemed = succeeded.select(&:redemption?).sum(&:amount)
      reversed = succeeded.select { |t| t.refund? && t.reversal_of_transaction_id.present? }.sum(&:amount)
      stripe_refunded = succeeded.select { |t| t.refund? && t.reversal_of_transaction_id.nil? }.sum(&:amount)
      written_off = succeeded.select { |t| t.adjustment? && t.processor_ref.to_s.start_with?("dispute_") }.sum(&:amount)
      lhs = redeemed - reversed - stripe_refunded - written_off
      rhs = card.total_loaded_cents.to_i - card.remaining_balance.to_i
      if lhs != rhs
        msg = "I3 redemptions #{redeemed} − reversals #{reversed} − stripe refunds #{stripe_refunded} − " \
              "write-offs #{written_off} = #{lhs} != total_loaded #{card.total_loaded_cents.to_i} − remaining #{card.remaining_balance.to_i} = #{rhs}"
        if card.canceled?
          warnings << "legacy canceled card: #{msg}"
        else
          drift << msg
        end
      end

      # I5 / allocation integrity — every redemption and reversal is fully
      # allocated, and every allocation points at a matching txn on this card.
      alloc_rows = RedemptionAllocation.where(gift_card_load_id: loads.map(&:id)).to_a
      by_txn = alloc_rows.group_by(&:transaction_id)
      txn_by_id = txns.index_by(&:id)

      succeeded.select(&:redemption?).each do |t|
        allocated = (by_txn[t.id] || []).select(&:debit?).sum(&:amount_cents)
        drift << "I5 redemption txn #{t.id} amount #{t.amount} but debit allocations #{allocated}" if allocated != t.amount
      end
      succeeded.select { |t| t.refund? && t.reversal_of_transaction_id.present? }.each do |t|
        allocated = (by_txn[t.id] || []).select(&:credit?).sum(&:amount_cents)
        drift << "I5 reversal txn #{t.id} amount #{t.amount} but credit allocations #{allocated}" if allocated != t.amount
      end
      alloc_rows.each do |a|
        t = txn_by_id[a.transaction_id]
        if t.nil?
          drift << "allocation #{a.id} points at txn #{a.transaction_id} not on this card"
        elsif !t.succeeded?
          drift << "allocation #{a.id} points at non-succeeded txn #{t.id}"
        elsif a.debit? && !t.redemption?
          drift << "allocation #{a.id} is a debit on non-redemption txn #{t.id}"
        elsif a.credit? && !(t.refund? && t.reversal_of_transaction_id.present?)
          drift << "allocation #{a.id} is a credit on non-reversal txn #{t.id}"
        end
      end

      CardReport.new(card_id: card.id, status: card.status, drift: drift, warnings: warnings, info: info)
    end

    private

    # { load_id => { "debit" => cents, "credit" => cents } }
    def allocation_sums(load_ids)
      RedemptionAllocation.where(gift_card_load_id: load_ids)
                          .group(:gift_card_load_id, :direction)
                          .sum(:amount_cents)
                          .each_with_object(Hash.new { |h, k| h[k] = {} }) do |((load_id, direction), cents), acc|
        acc[load_id][direction] = cents
      end
    end
  end
end
