class Transaction < ApplicationRecord
  belongs_to :gift_card

  # Enums
  enum txn_type: { purchase: 0, redemption: 1, refund: 2, adjustment: 3 }
  enum status: { pending: 0, succeeded: 1, failed: 2 }

  # Validations
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :txn_type, presence: true
  validates :status, presence: true
  validates :processor_ref, presence: true, uniqueness: true

  # Scopes
  scope :successful, -> { where(status: :succeeded) }
  scope :purchases, -> { where(txn_type: :purchase) }
  scope :redemptions, -> { where(txn_type: :redemption) }
  scope :refunds, -> { where(txn_type: :refund) }
end
