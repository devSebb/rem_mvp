class Settlement < ApplicationRecord
  belongs_to :merchant

  # Enums
  enum payout_status: { pending: 0, paid: 1, failed: 2 }

  # Validations
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :period_start, presence: true
  validates :period_end, presence: true
  validates :payout_status, presence: true

  # Validations
  validate :period_end_after_period_start

  # Scopes
  scope :pending, -> { where(payout_status: :pending) }
  scope :paid, -> { where(payout_status: :paid) }
  scope :failed, -> { where(payout_status: :failed) }

  # Get all transactions included in this settlement
  def transactions
    Transaction.where(merchant: merchant)
              .where(txn_type: :redemption, status: :succeeded)
              .where(created_at: period_start..period_end)
  end

  # Get all gift cards included in this settlement
  def gift_cards
    GiftCard.joins(:transactions)
            .where(transactions: { merchant: merchant, txn_type: :redemption, status: :succeeded })
            .where(transactions: { created_at: period_start..period_end })
            .distinct
  end

  # Calculate the total amount that should be settled for this period
  def calculated_amount
    transactions.sum(:amount)
  end

  # Check if the settlement amount matches the calculated amount
  def amount_matches_calculated?
    amount == calculated_amount
  end

  # Get settlement status for a specific gift card
  def gift_card_settlement_status(gift_card)
    gift_card_transactions = transactions.where(gift_card: gift_card)
    return 'not_included' if gift_card_transactions.empty?
    
    # For now, all transactions in a settlement are considered settled
    'settled'
  end

  private

  def period_end_after_period_start
    return unless period_start && period_end

    errors.add(:period_end, 'must be after period start') if period_end < period_start
  end
end
