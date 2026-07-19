# Redeemer-based settlement summaries for the merchant panel. Settlement
# CREATION lives in Admin::PayoutsController (net of reversals via
# Merchant#unsettled_*); the legacy issuer-based and gross-summing methods
# were removed 2026-07-19 — don't reintroduce settlement math that doesn't
# net reversals.
class SettlementService
  # Redeemer-based settlement summary: calculates settlement data from the perspective
  # of the merchant who REDEEMED the gift card, not who issued it.
  #
  # @param gift_card [GiftCard] The gift card to summarize
  # @param redeemer_merchant [Merchant] The merchant who performed the redemption(s)
  # @return [Hash] Settlement summary with :total_redeemed, :settled_amount, etc.
  def self.gift_card_settlement_summary_for_redeemer(gift_card, redeemer_merchant)
    batch = gift_card_settlement_summaries_for_redeemer([gift_card], redeemer_merchant)
    batch[gift_card.id] || {
      total_redeemed: 0,
      settled_amount: 0,
      remaining_to_settle: 0,
      settlement_status: "pending",
      last_redemption: nil,
      issuing_merchant: gift_card.merchant
    }
  end

  # Batch version: compute settlement summaries for multiple gift cards in a fixed number of queries.
  # Use this from the settlements index to avoid N+1.
  #
  # @param gift_cards [Array<GiftCard>]
  # @param redeemer_merchant [Merchant]
  # @return [Hash] gift_card_id => summary hash (same shape as gift_card_settlement_summary_for_redeemer)
  def self.gift_card_settlement_summaries_for_redeemer(gift_cards, redeemer_merchant)
    gift_card_ids = gift_cards.map(&:id).uniq
    return {} if gift_card_ids.empty?

    base_scope = Transaction.where(merchant: redeemer_merchant, txn_type: :redemption, status: :succeeded)
    reversal_scope = Transaction.successful.reversals.where(merchant: redeemer_merchant)

    # Total redeemed per gift card, net of reversals (two queries)
    total_redeemed_by_gc = base_scope.where(gift_card_id: gift_card_ids).group(:gift_card_id).sum(:amount)
    reversed_by_gc = reversal_scope.where(gift_card_id: gift_card_ids).group(:gift_card_id).sum(:amount)
    reversed_by_gc.each { |gc_id, cents| total_redeemed_by_gc[gc_id] = total_redeemed_by_gc[gc_id].to_i - cents }

    # Last redemption per gift card (one query)
    last_redemption_by_gc = base_scope.where(gift_card_id: gift_card_ids).group(:gift_card_id).maximum(:created_at)

    # Settled amount:
    # Load settlement periods and relevant redemption transactions once, then compute
    # per-settlement totals in memory to avoid 2 queries per settlement.
    settled_by_gc = Hash.new(0)
    settlements = redeemer_merchant.settlements.select(:id, :amount, :period_start, :period_end).to_a
    if settlements.any?
      min_start = settlements.map(&:period_start).min.beginning_of_day
      max_end = settlements.map(&:period_end).max.end_of_day
      gift_card_id_set = gift_card_ids.each_with_object({}) { |id, memo| memo[id] = true }

      # Reversal rows enter with a negative sign so every per-settlement
      # total and per-card share is automatically net.
      tx_rows = base_scope
                .where(created_at: min_start..max_end)
                .pluck(:created_at, :amount, :gift_card_id) +
                reversal_scope
                .where(created_at: min_start..max_end)
                .pluck(:created_at, :amount, :gift_card_id)
                .map { |created_at, amount, gc_id| [created_at, -amount, gc_id] }

      settlements.each do |settlement|
        total_settlement = 0
        by_gift_card = Hash.new(0)

        # Same day-inclusive window as Settlement#period_range — a bare
        # date comparison silently drops the period's last day.
        range = settlement.period_start.beginning_of_day..settlement.period_end.end_of_day

        tx_rows.each do |created_at, amount, gift_card_id|
          next unless range.cover?(created_at)

          total_settlement += amount
          by_gift_card[gift_card_id] += amount if gift_card_id_set[gift_card_id]
        end

        next if total_settlement <= 0

        by_gift_card.each do |gift_card_id, amount|
          proportion = amount.to_f / total_settlement
          settled_by_gc[gift_card_id] += (settlement.amount * proportion).round
        end
      end
    end

    gift_cards_by_id = gift_cards.index_by(&:id)
    gift_card_ids.map { |id|
      total_redeemed = total_redeemed_by_gc[id] || 0
      settled = settled_by_gc[id] || 0
      remaining = total_redeemed - settled
      [
        id,
        {
          total_redeemed: total_redeemed,
          settled_amount: settled,
          remaining_to_settle: remaining,
          settlement_status: remaining > 0 ? "pending" : "settled",
          last_redemption: last_redemption_by_gc[id],
          issuing_merchant: gift_cards_by_id[id]&.merchant
        }
      ]
    }.to_h
  end
end
