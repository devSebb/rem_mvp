class Settlement < ApplicationRecord
  belongs_to :merchant
  belongs_to :paid_by_admin, class_name: "User", optional: true

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

  # Get all transactions included in this settlement.
  # period_start/period_end are dates; created_at is a timestamp. Compare
  # against the full end day — a bare date range ends at midnight and would
  # silently drop every transaction from the settlement's last day.
  def transactions
    Transaction.where(merchant: merchant)
              .where(txn_type: :redemption, status: :succeeded)
              .where(created_at: period_range)
  end

  # Merchant reversals dated in this settlement's window: they reduce what
  # the merchant is paid for the period (including reversals of redemptions
  # that were already paid out in an earlier settlement).
  def reversals
    Transaction.successful.reversals
               .where(merchant: merchant)
               .where(created_at: period_range)
  end

  # Get all gift cards included in this settlement
  def gift_cards
    GiftCard.joins(:transactions)
            .where(transactions: { merchant: merchant, txn_type: :redemption, status: :succeeded })
            .where(transactions: { created_at: period_range })
            .distinct
  end

  def period_range
    period_start.beginning_of_day..period_end.end_of_day
  end

  # Total that should be settled for this period: redemptions net of
  # reversals dated in the window.
  def calculated_amount
    transactions.sum(:amount) - reversals.sum(:amount)
  end

  # Check if the settlement amount matches the calculated amount.
  # amount is stored net of platform commission (commission_amount is 0 on
  # legacy settlements created before commissions existed).
  def amount_matches_calculated?
    amount == calculated_amount - commission_amount.to_i
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
