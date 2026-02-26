class SettlementService
  def self.create_settlement_for_period(merchant, period_start, period_end, notes: nil)
    # Get all redemption transactions for the merchant in the specified period
    transactions = Transaction.where(merchant: merchant)
                            .where(txn_type: :redemption, status: :succeeded)
                            .where(created_at: period_start..period_end)
    
    return nil if transactions.empty?
    
    # Calculate the total amount to be settled
    total_amount = transactions.sum(:amount)
    
    # Create the settlement
    settlement = merchant.settlements.create!(
      amount: total_amount,
      period_start: period_start,
      period_end: period_end,
      payout_status: :pending,
      notes: notes
    )
    
    settlement
  end
  
  def self.calculate_pending_settlement(merchant)
    # Get all redemption transactions that haven't been settled yet
    all_redemption_transactions = Transaction.where(merchant: merchant)
                                           .where(txn_type: :redemption, status: :succeeded)
    
    # Get all transactions that are already included in settlements
    settled_transactions = Transaction.where(merchant: merchant, txn_type: :redemption, status: :succeeded)
    
    # Calculate pending amount (simplified for MVP)
    all_redemption_transactions.sum(:amount)
  end
  
  # DEPRECATED: This method uses issuer-based settlement logic.
  # Use gift_card_settlement_summary_for_redeemer instead.
  def self.gift_card_settlement_summary(gift_card)
    # Get all redemption transactions for this gift card
    redemption_transactions = gift_card.transactions.where(txn_type: :redemption, status: :succeeded)
    total_redeemed = redemption_transactions.sum(:amount)
    
    # Calculate settled amount by checking all settlements
    settled_amount = 0
    gift_card.merchant.settlements.each do |settlement|
      gift_card_transactions = settlement.transactions.where(gift_card: gift_card)
      if gift_card_transactions.any?
        total_settlement_transactions = settlement.transactions.sum(:amount)
        gift_card_amount_in_settlement = gift_card_transactions.sum(:amount)
        
        if total_settlement_transactions > 0
          proportion = gift_card_amount_in_settlement.to_f / total_settlement_transactions
          settled_amount += (settlement.amount * proportion).round
        end
      end
    end
    
    remaining_to_settle = total_redeemed - settled_amount
    
    {
      total_redeemed: total_redeemed,
      settled_amount: settled_amount,
      remaining_to_settle: remaining_to_settle,
      settlement_status: remaining_to_settle > 0 ? 'pending' : 'settled',
      last_redemption: redemption_transactions.order(created_at: :desc).first&.created_at
    }
  end
  
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

    # Total redeemed per gift card (one query)
    total_redeemed_by_gc = base_scope.where(gift_card_id: gift_card_ids).group(:gift_card_id).sum(:amount)

    # Last redemption per gift card (one query)
    last_redemption_by_gc = base_scope.where(gift_card_id: gift_card_ids).group(:gift_card_id).maximum(:created_at)

    # Settled amount:
    # Load settlement periods and relevant redemption transactions once, then compute
    # per-settlement totals in memory to avoid 2 queries per settlement.
    settled_by_gc = Hash.new(0)
    settlements = redeemer_merchant.settlements.select(:id, :amount, :period_start, :period_end).to_a
    if settlements.any?
      min_start = settlements.map(&:period_start).min
      max_end = settlements.map(&:period_end).max
      gift_card_id_set = gift_card_ids.each_with_object({}) { |id, memo| memo[id] = true }

      tx_rows = base_scope
                .where(created_at: min_start..max_end)
                .pluck(:created_at, :amount, :gift_card_id)

      settlements.each do |settlement|
        total_settlement = 0
        by_gift_card = Hash.new(0)

        tx_rows.each do |created_at, amount, gift_card_id|
          next if created_at < settlement.period_start || created_at > settlement.period_end

          total_settlement += amount
          by_gift_card[gift_card_id] += amount if gift_card_id_set[gift_card_id]
        end

        next if total_settlement.zero?

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
