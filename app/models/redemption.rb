class Redemption < ApplicationRecord
  DECLINE_REASONS = %w[
    invalid_token
    expired_token
    token_used
    gift_card_inactive
    insufficient_balance
  ].freeze

  belongs_to :merchant
  belongs_to :gift_card, optional: true
  belongs_to :redemption_token, optional: true

  enum status: { approved: 0, declined: 1 }

  validates :amount_cents, presence: true, numericality: { greater_than: 0 }
  validates :currency, presence: true
  validates :status, presence: true
  validates :idempotency_key, presence: true, uniqueness: { scope: :merchant_id }
  validates :decline_reason, presence: true, if: :declined?
  validates :gift_card, presence: true, unless: :invalid_token_decline?
  validates :redemption_token, presence: true, if: -> { approved? || declined? && decline_reason != "invalid_token" }
  validate :decline_reason_is_supported

  scope :for_idempotency, ->(merchant_id, key) { where(merchant_id: merchant_id, idempotency_key: key) }

  private

  def invalid_token_decline?
    declined? && decline_reason == "invalid_token"
  end

  def decline_reason_is_supported
    return if decline_reason.blank? || DECLINE_REASONS.include?(decline_reason)

    errors.add(:decline_reason, "is not supported")
  end
end

