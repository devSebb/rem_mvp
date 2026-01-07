class Transaction < ApplicationRecord
  belongs_to :gift_card, optional: true
  belongs_to :merchant, optional: true
  belongs_to :user, optional: true
  belongs_to :redemption_token, optional: true

  # Enums
  enum txn_type: { purchase: 0, redemption: 1, refund: 2, adjustment: 3, issuance: 4 }
  enum status: { pending: 0, succeeded: 1, failed: 2 }

  # Validations
  validates :amount, presence: true
  validates :amount, numericality: { greater_than: 0 }, unless: :adjustment?
  validates :amount, numericality: { greater_than_or_equal_to: 0 }, if: :adjustment?
  validates :txn_type, presence: true
  validates :status, presence: true
  validates :processor_ref, presence: true, uniqueness: true
  validates :currency, presence: true

  # Ensure idempotency is scoped to merchant when present
  validates :idempotency_key, uniqueness: { scope: :merchant_id }, allow_nil: true

  # Scopes
  scope :successful, -> { where(status: :succeeded) }
  scope :purchases, -> { where(txn_type: :purchase) }
  scope :redemptions, -> { where(txn_type: :redemption) }
  scope :refunds, -> { where(txn_type: :refund) }
end
