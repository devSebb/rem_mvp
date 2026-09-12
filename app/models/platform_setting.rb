# Single-row platform configuration, editable from the admin panel so fees
# and app-level switches can change without a deploy or app release.
# Fees are stored in basis points (100 bps = 1%) plus a fixed component in
# cents; both default to 0 (launch pricing).
class PlatformSetting < ApplicationRecord
  MAX_BPS = 2_500          # 25% — sanity ceiling, not a business target
  MAX_FIXED_CENTS = 1_000  # $10

  # ── Load caps (RELOADABLE_CARD_PLAN.md §4.1) ────────────────────────
  # Launch values are the column defaults (migration 20260912120000). The
  # ceilings below are LEGAL lines (FinCEN $2,000/device/day, $10,000/day
  # seller-of-prepaid-access, UAFE $10,000/30 d) and must never be raised
  # without counsel; the admin form can move a cap anywhere below them.
  LOAD_CAP_CEILINGS = {
    max_load_cents: 20_000,                    # $200 per load
    max_loads_per_card_per_day: 10,
    max_daily_load_per_card_cents: 200_000,    # $2,000 FinCEN device/day
    max_card_balance_cents: 200_000,           # $2,000
    max_daily_load_per_buyer_cents: 1_000_000, # $10,000 seller threshold
    max_daily_loads_per_buyer: 10,             # plan gives no legal ceiling; mirrors the per-card count ceiling
    max_30d_load_per_recipient_cents: 1_000_000, # $10,000 UAFE 30-day aggregation
    max_30d_load_per_buyer_cents: 1_000_000,     # $10,000
    buyer_refund_window_hours: 24 * 30         # D11: 72 h at launch; policy, not law
  }.freeze
  LOAD_CAP_MINIMUMS = {
    max_load_cents: GiftCardLoad::MIN_LOAD_CENTS,
    max_loads_per_card_per_day: 1,
    max_daily_load_per_card_cents: GiftCardLoad::MIN_LOAD_CENTS,
    max_card_balance_cents: GiftCardLoad::MIN_LOAD_CENTS,
    max_daily_load_per_buyer_cents: GiftCardLoad::MIN_LOAD_CENTS,
    max_daily_loads_per_buyer: 1,
    max_30d_load_per_recipient_cents: GiftCardLoad::MIN_LOAD_CENTS,
    max_30d_load_per_buyer_cents: GiftCardLoad::MIN_LOAD_CENTS,
    buyer_refund_window_hours: 0
  }.freeze

  belongs_to :updated_by, class_name: "User", optional: true

  validates :buyer_fee_bps, :merchant_commission_bps,
            numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: MAX_BPS }
  validates :buyer_fee_fixed_cents,
            numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: MAX_FIXED_CENTS }
  LOAD_CAP_CEILINGS.each do |attr, ceiling|
    validates attr, numericality: {
      only_integer: true,
      greater_than_or_equal_to: LOAD_CAP_MINIMUMS.fetch(attr),
      less_than_or_equal_to: ceiling
    }
  end
  # A single load must fit under every aggregate cap or the caps contradict.
  validate :load_caps_consistent

  # Snapshot of every cap, for Loads::CapChecker and `GET /config` (Phase 3).
  def load_caps
    LOAD_CAP_CEILINGS.keys.index_with { |attr| public_send(attr) }
  end

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

  private

  def load_caps_consistent
    return if max_load_cents.nil?

    %i[max_daily_load_per_card_cents max_card_balance_cents max_daily_load_per_buyer_cents
       max_30d_load_per_recipient_cents max_30d_load_per_buyer_cents].each do |attr|
      value = public_send(attr)
      next if value.nil? || value >= max_load_cents

      errors.add(attr, "must be at least max_load_cents (#{max_load_cents})")
    end
  end
end
