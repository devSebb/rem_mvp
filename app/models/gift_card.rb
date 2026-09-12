require "digest"

class GiftCard < ApplicationRecord
  # Deprecated (§3.1): set to the FIRST load's sender when the card is
  # created and never updated. The serializer's `sender` is the latest load's.
  belongs_to :sender, class_name: "User", optional: true
  belongs_to :recipient, class_name: "User"
  belongs_to :merchant
  # Phase 2 merge: a card absorbed into the survivor for its (recipient,
  # merchant) pair. Such rows are excluded from the unique pair index.
  belongs_to :merged_into, class_name: "GiftCard", optional: true
  has_many :transactions, dependent: :destroy
  has_many :redemption_tokens, dependent: :destroy
  # One row per payment credited onto this card (RELOADABLE_CARD_PLAN.md §3.2).
  # Oldest first = FIFO order for redemptions. Loads are only ever mutated
  # inside this card's `with_lock` (§6).
  has_many :loads, -> { fifo }, class_name: "GiftCardLoad", dependent: :destroy, inverse_of: :gift_card
  has_many :redemption_allocations, through: :loads
  class RedemptionError < StandardError
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super(reason.to_s)
    end
  end


  # Raw code is stored encrypted in encrypted_raw_code column
  # We handle encryption/decryption manually for compatibility

  # Enums. `redeemed` and `expired` are legacy values (D3): the Phase 1
  # backfill remapped existing rows to `active` and Phase 3 code never writes
  # them again. Status 4 is the plan's `frozen` (admin-only manual fraud
  # action); the enum key is `frozen_by_admin` because Rails refuses to
  # generate `frozen?` (it collides with Object#frozen?). The Phase 3
  # serializer may still expose it to clients as "frozen".
  enum status: { active: 0, redeemed: 1, expired: 2, canceled: 3, frozen_by_admin: 4 }

  # Constants
  MAX_AMOUNT_CENTS = 20_000 # $200.00 USD

  # Stripe Radar risk score thresholds. See docs/security-hold.md or
  # Refunds::IssueStripeRefund for the surrounding policy. Scores >= 75
  # are blocked at purchase time by Stripe itself (default Radar setting),
  # so we only need to handle the 65-74 elevated band here.
  RISK_HOLD_THRESHOLD = 65
  RISK_HOLD_DURATION = 24.hours

  # Scopes. Holds and disputes live on loads from Phase 3 on (§3.4); the
  # card-level columns are deprecated and no longer read.
  scope :currently_held, -> { where(id: GiftCardLoad.in_scope.currently_held.select(:gift_card_id)) }
  scope :disputed, -> { where(id: GiftCardLoad.in_scope.dispute_open.select(:gift_card_id)) }
  scope :not_merged, -> { where(merged_into_id: nil) }
  scope :active_or_frozen, -> { where(status: [statuses[:active], statuses[:frozen_by_admin]]) }

  # Validations. `sender` and `amount` are deprecated card columns (§3.1):
  # the buyer and the face value belong to each load. `amount` stays
  # mirrored to total_loaded_cents for old admin views; the per-load cap is
  # GiftCardLoad::MAX_LOAD_CENTS.
  validates :recipient, presence: true
  validates :amount, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :remaining_balance, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :currency, presence: true
  validates :code_digest, presence: true, uniqueness: true
  validates :status, presence: true
  validates :link_token_digest, uniqueness: true, allow_nil: true
  validates :otp_digest, uniqueness: true, allow_nil: true
  validates :merchant, presence: true

  # Callbacks
  before_validation :set_defaults, on: :create
  after_create :record_issuance_transaction_unless_stripe!
  after_create :seed_legacy_load!

  # Class methods
  def self.find_active_by_code(code)
    return nil if code.blank?

    normalized_code = normalize_code_for_lookup(code)
    code_fingerprint = fingerprint_for_code(normalized_code)
    lookup_hash = Digest::SHA256.hexdigest(normalized_code)

    if Rails.env.development?
      Rails.logger.debug "🔍 Looking for gift card with code fingerprint: #{code_fingerprint}"
    end

    # Indexed path: use code_lookup_hash when present (new and backfilled records)
    candidate = where(status: :active).find_by(code_lookup_hash: lookup_hash)
    if candidate
      begin
        if BCrypt::Password.new(candidate.code_digest) == normalized_code
          Rails.logger.info "✅ Found gift card #{candidate.id} (indexed lookup) for code fingerprint #{code_fingerprint}"
          return candidate
        end
      rescue BCrypt::Errors::InvalidHash => e
        Rails.logger.error "❌ Invalid code_digest for gift card #{candidate.id}: #{e.message}"
      end
      return nil # Hash matched but BCrypt failed; no need to try legacy
    end

    # Legacy path: for records without code_lookup_hash set yet
    found_card = legacy_find_active_by_code(normalized_code, code_fingerprint)
    Rails.logger.warn "[PARITY] find_active_by_code used legacy path for fingerprint #{code_fingerprint}" if found_card
    found_card
  end

  def self.legacy_find_active_by_code(normalized_code, code_fingerprint = fingerprint_for_code(normalized_code))
    gift_cards = where(status: :active)
    found = gift_cards.find do |gc|
      begin
        BCrypt::Password.new(gc.code_digest) == normalized_code
      rescue BCrypt::Errors::InvalidHash => e
        Rails.logger.error "❌ Invalid code_digest for gift card #{gc.id}: #{e.message}"
        false
      end
    end
    Rails.logger.info "✅ Found gift card #{found.id} (legacy) for code fingerprint #{code_fingerprint}" if found
    Rails.logger.warn "❌ No active gift card found for provided code (fingerprint: #{code_fingerprint})" unless found
    found
  end
  private_class_method :legacy_find_active_by_code

  def self.fingerprint_for_code(code)
    return "[blank]" if code.blank?

    Digest::SHA256.hexdigest(code)[0, 12]
  end
  private_class_method :fingerprint_for_code

  # One card per (recipient, merchant) (D1, I12). Insert-or-find under the
  # unique pair index: never check-then-insert (§6.3). Canceled cards are
  # returned too — the caller decides (a canceled card refuses loads until
  # an admin reactivates it, §5.2). Merge shells are never returned.
  def self.find_or_create_for!(recipient:, merchant:, first_sender: nil)
    existing = not_merged.find_by(recipient_id: recipient.id, merchant_id: merchant.id)
    return existing if existing

    create!(recipient: recipient, merchant: merchant, sender: first_sender, amount: 0, remaining_balance: 0, currency: "USD")
  rescue ActiveRecord::RecordNotUnique
    not_merged.find_by!(recipient_id: recipient.id, merchant_id: merchant.id)
  end

  # Instance methods
  def generate_code!
    # Only generate if we don't already have a code
    if encrypted_raw_code.blank? || raw_code.blank?
      new_raw_code = CodeGenerator.generate
      self.code_digest = BCrypt::Password.create(new_raw_code)
      self.raw_code = new_raw_code  # Store encrypted
      self.code_lookup_hash = Digest::SHA256.hexdigest(GiftCard.normalize_code_for_lookup(new_raw_code))
      save!
      new_raw_code
    else
      # Return existing code
      raw_code
    end
  end

  # ── Balances (§3.4, single source of truth) ─────────────────────────
  # remaining_balance = Σ remaining_cents over non-canceled loads (cached
  # column, kept in step under the card lock); held/disputed are computed
  # from the loads' timestamps; spendable is what a redemption may draw.
  # NEVER gate money on `load.status` — it is a cached label (§10.2c).
  def balances
  now = Time.current
  remaining = 0
  held = 0
  disputed = 0
  earliest_hold = nil

  loads.each do |load|
    next if load.status_canceled?

    cents = load.remaining_cents.to_i
    remaining += cents
    if load.disputed_at.present? && load.dispute_outcome.nil?
      disputed += cents
    elsif load.held_until.present? && load.held_until > now
      held += cents
      earliest_hold = load.held_until if earliest_hold.nil? || load.held_until < earliest_hold
    end
  end

  {
    remaining_balance: remaining,
    held_cents: held,
    disputed_cents: disputed,
    spendable_cents: active? ? remaining - held - disputed : 0,
    held_until: (earliest_hold if held.positive?)
  }
end

  def spendable_cents
  balances[:spendable_cents]
end

  # Hold / dispute predicates now answer "does any load on this card carry
  # a hold / an open dispute?". The deprecated card columns are ignored.
  def held?
  balances[:held_cents].positive?
end

  def hold_remaining_seconds
  until_at = balances[:held_until]
  return 0 unless until_at

  [(until_at - Time.current).to_i, 0].max
end

  def disputed?
  balances[:disputed_cents].positive?
end

  # Gift cards never expire (no-expiration policy)
  def expired?
    false
  end

  # Update last_owner_activity_at without touching updated_at
  # Safe to call frequently and will not raise if record is invalid
  def touch_owner_activity!(time = Time.current)
    update_columns(last_owner_activity_at: time) if persisted?
  rescue => e
    Rails.logger.warn "⚠️ Failed to touch owner activity for gift card #{id}: #{e.message}"
    # Silently fail to avoid breaking the request flow
  end

  def can_be_redeemed?
  active? && spendable_cents.positive?
end

  def total_redemptions
  transactions.successful.redemptions.sum(:amount)
end

  # Max amount refundable to buyers at Stripe across all loads (Type B):
  # the sum of each load's unredeemed, not-yet-refunded part. Refunds are
  # issued per load (Refunds::IssueStripeRefund); this is for admin views.
  def refundable_to_buyer_cents
  return 0 if canceled?

  loads.select { |l| l.payment_intent_id.present? }.sum(&:refundable_cents)
end

  # ── Ledger invariants (RELOADABLE_CARD_PLAN.md §7) ──────────────────
  # Per-card drift report; empty array means every invariant holds. The
  # full check (all cards, aggregate report) is Ledger::Verifier / the
  # `ledger:verify` rake task; specs call `verify_ledger!` after every money
  # mutation.
  def ledger_drift
    Ledger::Verifier.card_drift(self)
  end

  def ledger_balanced?
    ledger_drift.empty?
  end

  def verify_ledger!
    drift = ledger_drift
    raise Ledger::Verifier::DriftError, "gift card #{id}: #{drift.join('; ')}" if drift.any?

    true
  end

  # NOTE: redemption reversals go through Refunds::Issue (writes the
  # reversal_of_transaction_id marker every money aggregate nets against).
  # A legacy GiftCard#refund! that wrote unmarked reversal rows was removed
  # 2026-07-19 — do not reintroduce reversal writes outside Refunds::Issue.

  # removed (D9): transfers — balance never moves between users.

  # Console convenience: (re)deliver the notification for the latest load.
  # Loads::Fulfill enqueues per load itself (§5.9).
  def send_notifications!
    return false unless recipient.present?

    load = loads.in_scope.fifo.last
    return false unless load

    LoadNotificationJob.perform_later(load.id)
    true
  end

  # First (oldest, non-canceled) load: the one whose delivery announced the
  # card; every later load is a reload (§5.9 template branching).
  def first_load
    loads.in_scope.fifo.first
  end

  def latest_load
    loads.in_scope.fifo.last
  end

  # Latest load paid by `user` — what the card-level share/resend compat
  # shims act on (§5.9).
  def latest_load_sent_by(user)
    return nil unless user

    loads.in_scope.where(sender_id: user.id).fifo.last
  end

  # Everyone who has ever paid onto this card (policy scope, §5.10).
  def sent_by?(user)
    return false unless user

    loads.in_scope.where(sender_id: user.id).exists?
  end

  # Public status label (§8.1): the enum key is frozen_by_admin (§10.2a).
  def public_status
    return "frozen" if frozen_by_admin?
    return "active" if redeemed? || expired?

    status
  end

  # Method to get raw code for display (only for recipients)
  # Note: This should only be called when we know the user has permission
  # The raw code is stored encrypted in the database and decrypted when accessed
  def raw_code
    # If we have an encrypted code, decrypt and return it
    if encrypted_raw_code.present?
      decrypt_raw_code
    else
      # No code stored yet - generate one (should only happen for old records)
      Rails.logger.warn "⚠️ Gift card #{id} has no stored raw code, generating new one"
      generate_code!
    end
  end

  # Setter for raw_code (stores encrypted)
  def raw_code=(value)
    return if value.blank?
    self.encrypted_raw_code = encrypt_raw_code(value)
  end

  private

  # Encrypt raw code for storage
  def encrypt_raw_code(code)
    return nil if code.blank?
    key = Rails.application.credentials.secret_key_base || Rails.application.secret_key_base
    encryptor = ActiveSupport::MessageEncryptor.new(key[0..31])
    encryptor.encrypt_and_sign(code)
  end

  # Decrypt raw code for display
  def decrypt_raw_code
    return nil if encrypted_raw_code.blank?
    key = Rails.application.credentials.secret_key_base || Rails.application.secret_key_base
    encryptor = ActiveSupport::MessageEncryptor.new(key[0..31])
    encryptor.decrypt_and_verify(encrypted_raw_code)
  rescue => e
    Rails.logger.error "❌ Failed to decrypt raw code for gift card #{id}: #{e.message}"
    nil
  end

  def set_defaults
    self.currency ||= "USD"
    self.status ||= :active

    # Generate code and store digest + encrypted raw code + lookup hash for fast redemption
    if code_digest.blank?
      raw_code_value = CodeGenerator.generate
      self.code_digest = BCrypt::Password.create(raw_code_value)
      self.raw_code = raw_code_value  # Store encrypted
      self.code_lookup_hash = Digest::SHA256.hexdigest(GiftCard.normalize_code_for_lookup(raw_code_value))
    end

    self.remaining_balance = amount if amount.present? && remaining_balance == 0
    # Legacy creation path (webhook / admin / seeds) still funds the card via
    # `amount`. Mirror it so the DB CHECK `total_loaded_cents >= remaining_balance`
    # holds until Phase 3's Loads::Fulfill maintains the counter itself.
    self.total_loaded_cents = amount if amount.present? && total_loaded_cents.to_i.zero?
  end

  def self.normalize_code_for_lookup(code)
    code.to_s.strip.upcase.gsub(/\s+/, "")
  end

  # For non-Stripe issuance (seeds, admin-issued, manual test cards), record an issuance transaction
  # so the ledger is complete. Stripe-created cards will have checkout_session_id or payment_intent_id
  # and are handled by `StripeWebhooks`, which creates a `purchase` transaction instead.
  def record_issuance_transaction_unless_stripe!
    return if checkout_session_id.present?
    return if payment_intent_id.present?
    return if transactions.purchases.exists?
    return if amount.blank? || amount.to_i <= 0

    transactions.create!(
      amount: amount,
      txn_type: :issuance,
      status: :succeeded,
      processor_ref: "issuance_#{SecureRandom.uuid}",
      merchant: merchant,
      user: sender,
      currency: currency,
      metadata: {
        source: "non_stripe_issuance"
      }
    )
  rescue => e
    Rails.logger.error "💥 Failed to record issuance transaction for gift card #{id}: #{e.class} - #{e.message}"
    # Don't block gift card creation if ledger write fails; log and move on.
  end

  # Legacy issuance path (admin console, seeds, specs): a card created with
  # a face value `amount` and no loads gets exactly one load for it, linked
  # to the issuance ledger row, so every creation path is ledger-consistent
  # (I1–I3). Phase 3 code (Loads::Fulfill) creates cards with amount 0 and
  # adds loads explicitly, so this never fires for Stripe purchases.
  def seed_legacy_load!
  return if amount.to_i <= 0
  return if loads.exists?

  load = loads.create!(
    sender: sender,
    source: (payment_intent_id.present? || checkout_session_id.present?) ? :stripe : :issuance,
    payment_intent_id: payment_intent_id,
    checkout_session_id: checkout_session_id,
    amount_cents: amount,
    remaining_cents: remaining_balance.to_i.clamp(0, amount),
    currency: currency,
    note: note,
    risk_score: risk_score,
    risk_level: risk_level,
    held_until: held_until,
    disputed_at: disputed_at
  )
  transactions.where(txn_type: [:issuance, :purchase], gift_card_load_id: nil).update_all(gift_card_load_id: load.id)
  update_columns(last_loaded_at: load.created_at)
end
end
