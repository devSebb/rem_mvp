# One payment (or admin issuance / adjustment) credited onto a gift card.
# RELOADABLE_CARD_PLAN.md §3.2. The card is the recipient's; each load has
# its own buyer, Stripe payment intent, Radar hold, dispute and refund state,
# and its own `remaining_cents`, so every Stripe event can be unwound to the
# exact dollars it concerns. Redemptions draw loads down oldest-first and
# record what they consumed in redemption_allocations.
#
# MONEY RULE (§6): never mutate remaining_cents / refunded_cents /
# written_off_cents / status on a load except inside the owning card's
# `with_lock` block. Never `with_lock` a load directly.
class GiftCardLoad < ApplicationRecord
  # Hard ceiling per load (§4.1). The launch value lives in
  # PlatformSetting#max_load_cents and may be lower, never higher.
  MAX_LOAD_CENTS = 20_000 # $200.00
  MIN_LOAD_CENTS = 500    # $5.00 (launch floor; issuance/adjustment loads may be smaller)

  # loads_count on gift_cards is maintained by this counter cache (an
  # arithmetic UPDATE, so it is safe under the card lock — §6.7). Phase 3
  # code must NOT increment loads_count by hand on top of this.
  belongs_to :gift_card, counter_cache: :loads_count
  belongs_to :sender, class_name: "User", optional: true
  belongs_to :hold_released_by, class_name: "User", optional: true
  has_many :transactions, dependent: :nullify
  has_many :redemption_allocations, dependent: :destroy

  enum source: { stripe: 0, issuance: 1, migration_merge: 2, admin_adjustment: 3 }, _prefix: :source

  # Derived, kept in sync for querying (§3.2). The cents columns and the
  # timestamps are the truth — see #derived_status.
  enum status: {
    available: 0, held: 1, disputed: 2, exhausted: 3, refunded: 4, written_off: 5, canceled: 6
  }, _prefix: :status

  validates :amount_cents, presence: true,
            numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_LOAD_CENTS }
  validates :remaining_cents, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :refunded_cents, :written_off_cents,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :currency, presence: true
  validates :payment_intent_id, uniqueness: true, allow_nil: true
  validates :checkout_session_id, uniqueness: true, allow_nil: true
  validates :dispute_outcome, inclusion: { in: %w[won lost] }, allow_nil: true
  validate :remaining_within_amount

  before_validation :set_defaults, on: :create
  # `status` is derived from the money columns and timestamps on every save,
  # so callers only ever change cents / held_until / disputed_at / outcome.
  # `canceled` is the one sticky value (see #derived_status). Time-based
  # flips (a hold expiring) still need #sync_status!.
  before_validation :derive_status

  # ── Scopes ──────────────────────────────────────────────────────────
  scope :fifo, -> { order(:created_at, :id) }
  scope :in_scope, -> { where.not(status: :canceled) }
  scope :currently_held, -> { where("held_until IS NOT NULL AND held_until > ?", Time.current) }
  scope :dispute_open, -> { where.not(disputed_at: nil).where(dispute_outcome: nil) }
  scope :with_balance, -> { where("remaining_cents > 0") }
  # Loads a redemption may draw from (§3.4 spendable): funds present, not
  # held, no open dispute, not canceled.
  scope :spendable, -> {
    in_scope.with_balance
            .where("held_until IS NULL OR held_until <= ?", Time.current)
            .where("disputed_at IS NULL OR dispute_outcome IS NOT NULL")
  }

  # ── Predicates ──────────────────────────────────────────────────────
  def held?
    held_until.present? && held_until > Time.current
  end

  def hold_remaining_seconds
    return 0 unless held?

    (held_until - Time.current).to_i
  end

  def dispute_open?
    disputed_at.present? && dispute_outcome.nil?
  end

  def spendable?
    !status_canceled? && remaining_cents.positive? && !held? && !dispute_open?
  end

  def spendable_cents
    spendable? ? remaining_cents : 0
  end

  # What this load can still be refunded to its buyer at Stripe (§5.7):
  # the unredeemed, not-yet-refunded part.
  def refundable_cents
    return 0 if dispute_open? || status_canceled?

    [remaining_cents, amount_cents - refunded_cents].min.clamp(0, amount_cents)
  end

  # ── Ledger helpers (I2) ─────────────────────────────────────────────
  def debited_cents
    redemption_allocations.debit.sum(:amount_cents)
  end

  def credited_cents
    redemption_allocations.credit.sum(:amount_cents)
  end

  def net_redeemed_cents
    debited_cents - credited_cents
  end

  # I2: remaining + refunded + written_off + Σdebit − Σcredit == amount.
  def ledger_balanced?
    remaining_cents + refunded_cents + written_off_cents + net_redeemed_cents == amount_cents
  end

  # Status as implied by the money columns and timestamps. `canceled` is
  # sticky (only an admin sets it) and is never derived.
  def derived_status
    return :canceled if status_canceled?
    return :written_off if remaining_cents.zero? && written_off_cents.positive?
    return :refunded if remaining_cents.zero? && refunded_cents.positive?
    return :exhausted if remaining_cents.zero?
    return :disputed if dispute_open?
    return :held if held?

    :available
  end

  def status_in_sync?
    status.to_sym == derived_status
  end

  # Call inside the owning card's lock after any money mutation.
  def sync_status!
    new_status = derived_status
    update_column(:status, self.class.statuses[new_status]) unless status.to_sym == new_status
    new_status
  end

  private

  def set_defaults
    self.currency ||= gift_card&.currency || "USD"
    self.remaining_cents = amount_cents if remaining_cents.nil? && amount_cents.present?
    self.refunded_cents ||= 0
    self.written_off_cents ||= 0
    self.fee_cents ||= 0
  end

  def derive_status
    return if remaining_cents.nil? || amount_cents.nil?

    self.status = derived_status
  end

  def remaining_within_amount
    return if remaining_cents.nil? || amount_cents.nil?
    return if remaining_cents <= amount_cents

    errors.add(:remaining_cents, "cannot exceed amount_cents")
  end
end
