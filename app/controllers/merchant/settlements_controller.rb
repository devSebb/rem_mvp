class Merchant::SettlementsController < ApplicationController
  before_action :ensure_merchant
  before_action :set_settlement, only: [:show]

  def index
    @merchant = current_user.merchant
    
    # Get all settlements for this merchant (redeemer)
    @settlements = @merchant.settlements.order(created_at: :desc)
    
    # Get all gift cards that have been REDEEMED BY this merchant (redeemer-paid model)
    # Note: This finds gift cards where THIS merchant performed a redemption,
    # regardless of who issued the gift card.
    @redeemed_gift_cards = GiftCard.joins(:transactions)
                                  .where(transactions: { merchant: @merchant, txn_type: :redemption, status: :succeeded })
                                  .includes(:sender, :recipient, :merchant, :transactions)
                                  .distinct
                                  .order(created_at: :desc)
    
    # Calculate settlement data for each gift card using the service (redeemer-based)
    @gift_card_settlements = @redeemed_gift_cards.map do |gift_card|
      summary = SettlementService.gift_card_settlement_summary_for_redeemer(gift_card, @merchant)
      {
        gift_card: gift_card,
        **summary
      }
    end
    
    # Summary statistics
    @total_pending_settlement = @gift_card_settlements.sum { |gc| gc[:remaining_to_settle] }
    @total_settled_amount = @gift_card_settlements.sum { |gc| gc[:settled_amount] }
    @total_redeemed_amount = @gift_card_settlements.sum { |gc| gc[:total_redeemed] }
    
    # Filter options
    @status_filter = params[:status] || 'all'
    @gift_card_settlements = filter_by_status(@gift_card_settlements, @status_filter)
  end

  def show
    @merchant = current_user.merchant
    
    # Get all transactions REDEEMED BY this merchant for this settlement period (redeemer-paid model)
    @settlement_transactions = Transaction.where(merchant: @merchant)
                                        .where(txn_type: :redemption, status: :succeeded)
                                        .where(created_at: @settlement.period_start..@settlement.period_end)
                                        .includes(gift_card: [:sender, :recipient, :merchant])
                                        .order(created_at: :desc)
    
    # Group by gift card for detailed view
    @gift_cards_in_settlement = @settlement_transactions.group_by(&:gift_card)
  end

  private

  def ensure_merchant
    unless current_user&.merchant?
      flash[:alert] = 'You must be a merchant to access this area.'
      redirect_to root_path
    end
  end

  def set_settlement
    @settlement = current_user.merchant.settlements.find(params[:id])
  end
  
  def filter_by_status(gift_card_settlements, status)
    case status
    when 'pending'
      gift_card_settlements.select { |gc| gc[:settlement_status] == 'pending' }
    when 'settled'
      gift_card_settlements.select { |gc| gc[:settlement_status] == 'settled' }
    else
      gift_card_settlements
    end
  end
end
