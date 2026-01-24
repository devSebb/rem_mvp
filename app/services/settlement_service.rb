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
    # Get redemption transactions for this gift card performed BY the specified redeemer
    redemption_transactions = gift_card.transactions
                                       .where(merchant: redeemer_merchant)
                                       .where(txn_type: :redemption, status: :succeeded)
    
    total_redeemed = redemption_transactions.sum(:amount)
    
    # Calculate settled amount by checking the REDEEMER's settlements (not issuer's)
    settled_amount = 0
    redeemer_merchant.settlements.each do |settlement|
      # settlement.transactions already scopes by settlement.merchant (redeemer)
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
      last_redemption: redemption_transactions.order(created_at: :desc).first&.created_at,
      issuing_merchant: gift_card.merchant # Include issuer info for transparency
    }
  end
end
