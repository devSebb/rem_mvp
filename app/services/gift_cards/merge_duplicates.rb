# Phase 2 merge (RELOADABLE_CARD_PLAN.md §10 Phase 2 step 2–3).
#
# For every (recipient_id, merchant_id) pair that still has more than one
# non-merged gift card, fold every card into one survivor (the oldest
# non-canceled card; the oldest card if all are canceled):
#   * gift_card_loads, transactions and redemption_tokens are re-pointed to
#     the survivor — nothing is deleted, every row keeps its history;
#   * the survivor's cached counters are recomputed from its loads;
#   * absorbed cards become `canceled` with `merged_into_id` set and a zero
#     balance, so the Phase 2 unique pair index can be created.
#
# Money safety:
#   * each group is one transaction with every card row locked (id order);
#   * an absorbed canceled card must be fully voided already (zero balance
#     on the card and on its loads) — otherwise the merge would resurrect
#     money an admin voided. Such groups are SKIPPED and listed for review;
#   * after re-pointing, the survivor is run through Ledger::Verifier and the
#     group rolls back on any drift;
#   * settlement math reads transactions.merchant_id only (I10), which the
#     merge never touches.
#
# DRY_RUN prints the same report and writes nothing.
module GiftCards
  class MergeDuplicates
    class DriftAfterMerge < StandardError; end

    Group = Struct.new(:recipient_id, :merchant_id, :cards, :survivor, :skipped_reason, :result, keyword_init: true) do
      def absorbed = cards.reject { |c| c.id == survivor.id }
      def skipped? = skipped_reason.present?
    end

    Result = Struct.new(:groups, :dry_run, keyword_init: true) do
      def merged = groups.reject(&:skipped?)
      def skipped = groups.select(&:skipped?)
    end

    def self.call(dry_run: true, io: $stdout)
      new(dry_run: dry_run, io: io).call
    end

    def initialize(dry_run:, io:)
      @dry_run = dry_run
      @io = io
    end

    def call
      groups = find_groups
      groups.each { |group| plan(group) }
      groups.reject(&:skipped?).each { |group| merge!(group) } unless @dry_run
      result = Result.new(groups: groups, dry_run: @dry_run)
      report(result)
      result
    end

    # ── Planning ────────────────────────────────────────────────────────

    def find_groups
      pairs = GiftCard.where(merged_into_id: nil)
                      .group(:recipient_id, :merchant_id)
                      .having("COUNT(*) > 1")
                      .count.keys.sort

      pairs.map do |recipient_id, merchant_id|
        cards = GiftCard.where(merged_into_id: nil, recipient_id: recipient_id, merchant_id: merchant_id)
                        .order(:created_at, :id).to_a
        Group.new(recipient_id: recipient_id, merchant_id: merchant_id, cards: cards)
      end
    end

    def plan(group)
      group.survivor = group.cards.reject(&:canceled?).min_by { |c| [c.created_at, c.id] } || group.cards.first

      no_loads = group.cards.select { |c| !c.loads.exists? }
      if no_loads.any?
        group.skipped_reason = "card(s) #{no_loads.map(&:id).inspect} have no loads — run `rake ledger:backfill_missing_loads` first"
        return
      end

      frozen = group.cards.select(&:frozen_by_admin?)
      if frozen.any?
        group.skipped_reason = "card(s) #{frozen.map(&:id).inspect} are frozen by an admin — resolve before merging"
        return
      end

      with_money = group.absorbed.select do |c|
        c.canceled? && (c.remaining_balance.to_i.positive? || c.loads.in_scope.sum(:remaining_cents).positive?)
      end
      if with_money.any?
        group.skipped_reason = "canceled card(s) #{with_money.map(&:id).inspect} still carry a balance — void (zero) or reactivate them manually"
        return
      end

      group.result = projected_result(group)
    end

    def projected_result(group)
      load_ids = GiftCardLoad.where(gift_card_id: group.cards.map(&:id))
      in_scope = load_ids.in_scope
      {
        remaining_balance: in_scope.sum(:remaining_cents),
        total_loaded_cents: in_scope.sum(:amount_cents),
        loads_count: load_ids.count,
        transactions: Transaction.where(gift_card_id: group.cards.map(&:id)).count,
        redemption_tokens: RedemptionToken.where(gift_card_id: group.cards.map(&:id)).count
      }
    end

    # ── Execution ───────────────────────────────────────────────────────

    def merge!(group)
      now = Time.current

      GiftCard.transaction do
        cards = GiftCard.where(id: group.cards.map(&:id)).order(:id).lock.to_a
        survivor = cards.find { |c| c.id == group.survivor.id }
        absorbed = cards.reject { |c| c.id == survivor.id }
        absorbed_ids = absorbed.map(&:id)

        GiftCardLoad.where(gift_card_id: absorbed_ids).update_all(gift_card_id: survivor.id, updated_at: now)
        Transaction.where(gift_card_id: absorbed_ids).update_all(gift_card_id: survivor.id, updated_at: now)
        RedemptionToken.where(gift_card_id: absorbed_ids).update_all(gift_card_id: survivor.id, updated_at: now)

        loads = GiftCardLoad.where(gift_card_id: survivor.id)
        in_scope = loads.in_scope
        survivor.update_columns(
          remaining_balance: in_scope.sum(:remaining_cents),
          total_loaded_cents: in_scope.sum(:amount_cents),
          # Keep the deprecated `amount` mirrored (old admin views, Phase 3 keeps doing this).
          amount: in_scope.sum(:amount_cents),
          loads_count: loads.count,
          last_loaded_at: loads.maximum(:created_at),
          # Deprecated card-level guards, propagated so any code still reading
          # them errs on the side of blocking until Phase 3 reads the loads.
          held_until: cards.map(&:held_until).compact.max,
          disputed_at: cards.map(&:disputed_at).compact.min,
          updated_at: now
        )

        absorbed.each do |card|
          card.update_columns(
            status: GiftCard.statuses[:canceled],
            merged_into_id: survivor.id,
            remaining_balance: 0,
            total_loaded_cents: 0,
            loads_count: 0,
            updated_at: now
          )
        end

        drift = Ledger::Verifier.card_drift(survivor.reload)
        raise DriftAfterMerge, "survivor #{survivor.id}: #{drift.join('; ')}" if drift.any?

        group.result = {
          remaining_balance: survivor.remaining_balance,
          total_loaded_cents: survivor.total_loaded_cents,
          loads_count: survivor.loads_count,
          transactions: Transaction.where(gift_card_id: survivor.id).count,
          redemption_tokens: RedemptionToken.where(gift_card_id: survivor.id).count
        }
      end
    end

    # ── Report ──────────────────────────────────────────────────────────

    def report(result)
      mode = result.dry_run ? "DRY RUN — nothing written" : "APPLIED"
      @io.puts "🔀 gift_cards:merge_duplicates (#{mode})"
      @io.puts "   #{result.groups.size} duplicate (recipient, merchant) pair(s)"

      result.groups.each do |group|
        merchant = Merchant.find_by(id: group.merchant_id)
        @io.puts ""
        @io.puts "   recipient #{group.recipient_id} × merchant #{group.merchant_id} (#{merchant&.store_name || '?'}): #{group.cards.size} cards"
        group.cards.each do |card|
          role = card.id == group.survivor.id ? "SURVIVOR" : "absorb"
          @io.puts format("     #%-6d %-9s bal %8d / loaded %8d  loads %2d  created %s  %s",
                          card.id, card.status, card.remaining_balance.to_i, card.total_loaded_cents.to_i,
                          card.loads_count.to_i, card.created_at.to_date, role)
        end
        if group.skipped?
          @io.puts "     ⏭  SKIPPED: #{group.skipped_reason}"
        else
          r = group.result
          @io.puts "     → survivor ##{group.survivor.id}: balance #{r[:remaining_balance]}, loaded #{r[:total_loaded_cents]}, " \
                   "loads #{r[:loads_count]}, txns #{r[:transactions]}, tokens #{r[:redemption_tokens]}"
        end
      end

      @io.puts ""
      @io.puts "   merged: #{result.merged.size}, skipped: #{result.skipped.size}"
      @io.puts "   ⚠️  skipped groups block the Phase 2 unique index — resolve them and re-run" if result.skipped.any?
    end
  end
end
