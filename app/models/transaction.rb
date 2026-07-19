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
  # Merchant redemption reversals (Type A): value returned onto the card,
  # so the merchant is owed that much less. Stripe buyer refunds (Type B)
  # have no reversal_of_transaction_id and must never reduce merchant money.
  scope :reversals, -> { refunds.where.not(reversal_of_transaction_id: nil) }

  # ── Central netting API ─────────────────────────────────────────────
  # Every surface that shows or pays out merchant redemption money must go
  # through these, so "redeemed" always means net of reversals everywhere.

  def self.net_redeemed_cents(merchant_id:, period: nil)
    reds = successful.redemptions.where(merchant_id: merchant_id)
    revs = successful.reversals.where(merchant_id: merchant_id)
    if period
      reds = reds.where(created_at: period)
      revs = revs.where(created_at: period)
    end
    reds.sum(:amount) - revs.sum(:amount)
  end

  # Grouped variant for index pages: { merchant_id => net_cents }.
  # Includes merchants that only have reversals (negative net).
  def self.net_redeemed_cents_by_merchant
    reds = successful.redemptions.group(:merchant_id).sum(:amount)
    revs = successful.reversals.group(:merchant_id).sum(:amount)
    (reds.keys | revs.keys).index_with { |id| reds[id].to_i - revs[id].to_i }
  end

  # Platform-wide net (all merchants) — the admin dashboard's owed basis.
  def self.total_net_redeemed_cents
    successful.redemptions.sum(:amount) - successful.reversals.sum(:amount)
  end
end
