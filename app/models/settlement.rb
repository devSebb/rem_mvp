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

  private

  def period_end_after_period_start
    return unless period_start && period_end

    errors.add(:period_end, 'must be after period start') if period_end < period_start
  end
end
