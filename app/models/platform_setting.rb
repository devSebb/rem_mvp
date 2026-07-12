# Single-row platform configuration, editable from the admin panel so fees
# and app-level switches can change without a deploy or app release.
# Fees are stored in basis points (100 bps = 1%) plus a fixed component in
# cents; both default to 0 (launch pricing).
class PlatformSetting < ApplicationRecord
  MAX_BPS = 2_500          # 25% — sanity ceiling, not a business target
  MAX_FIXED_CENTS = 1_000  # $10

  belongs_to :updated_by, class_name: "User", optional: true

  validates :buyer_fee_bps, :merchant_commission_bps,
            numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: MAX_BPS }
  validates :buyer_fee_fixed_cents,
            numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: MAX_FIXED_CENTS }

  def self.current
    first || create!
  end

  # Service fee the buyer pays on top of the gift-card face value.
  def buyer_fee_cents_for(subtotal_cents)
    ((subtotal_cents * buyer_fee_bps) / 10_000.0).round + buyer_fee_fixed_cents
  end

  # Platform cut withheld from merchant settlements.
  def merchant_commission_cents_for(amount_cents)
    ((amount_cents * merchant_commission_bps) / 10_000.0).round
  end
end
