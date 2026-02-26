require "digest"

class GiftCard < ApplicationRecord
  belongs_to :sender, class_name: "User"
  belongs_to :recipient, class_name: "User"
  belongs_to :merchant
  has_many :transactions, dependent: :destroy
  has_many :redemption_tokens, dependent: :destroy
  class RedemptionError < StandardError
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super(reason.to_s)
    end
  end


  # Raw code is stored encrypted in encrypted_raw_code column
  # We handle encryption/decryption manually for compatibility

  # Enums
  enum status: { active: 0, redeemed: 1, expired: 2, canceled: 3 }

  # Constants
  MAX_AMOUNT_CENTS = 20_000 # $200.00 USD

  # Validations
  validates :sender, presence: true
  validates :recipient, presence: true
  validates :amount, presence: true, numericality: { greater_than: 0, less_than_or_equal_to: MAX_AMOUNT_CENTS }
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

  def redeem!(merchant:, actor:)
    partial_redeem!(redemption_amount: remaining_balance, merchant: merchant, actor: actor)
  end
  def redeem_amount!(amount_cents)
    cents = amount_cents.to_i
    raise RedemptionError.new(:invalid_amount) if cents <= 0

    with_lock do
      reload

      raise RedemptionError.new(:gift_card_inactive) unless active? && !expired?
      raise RedemptionError.new(:insufficient_balance) if cents > remaining_balance

      new_balance = remaining_balance - cents
      updates = { remaining_balance: new_balance }
      if new_balance.zero?
        updates[:status] = :redeemed
        updates[:redeemed_at] = Time.current
      end

      update!(updates)
      new_balance
    end
  end

  def partial_redeem!(redemption_amount:, merchant:, actor:)
    Rails.logger.info "🔄 partial_redeem! called - Amount: #{redemption_amount}, Merchant: #{merchant&.id}, Actor: #{actor&.id}"

    if merchant.nil?
      Rails.logger.error "❌ Merchant is nil"
      return false
    end

    if actor.nil?
      Rails.logger.error "❌ Actor is nil"
      return false
    end

    transaction do
      # Pessimistic locking to prevent race conditions
      lock!
      reload # Get latest balance from database

      Rails.logger.info "   Current balance: #{remaining_balance}, Status: #{status}"

      unless can_partial_redeem?(redemption_amount)
        Rails.logger.error "❌ Cannot partial redeem - can_partial_redeem? returned false"
        return false
      end

      # Create redemption transaction
      txn = transactions.create!(
        amount: redemption_amount,
        txn_type: :redemption,
        status: :succeeded,
        processor_ref: "ui_redemption_#{SecureRandom.uuid}",
        merchant: merchant,
        user: actor,
        currency: currency,
        metadata: {
          actor_id: actor.id,
          actor_type: actor.class.name,
          merchant_id: merchant.id,
          redeemed_at: Time.current.iso8601
        }
      )

      Rails.logger.info "   ✅ Created transaction #{txn.id}"

      # Update remaining balance
      new_balance = remaining_balance - redemption_amount
      update!(
        remaining_balance: new_balance
      )

      # Track owner activity for redemption
      touch_owner_activity!

      Rails.logger.info "   ✅ Updated balance: #{new_balance}"

      # Mark as fully redeemed if balance is zero
      if new_balance == 0
        update!(
          status: :redeemed,
          redeemed_at: Time.current
        )
        Rails.logger.info "   ✅ Marked as fully redeemed"
      end
    end

    Rails.logger.info "✅ partial_redeem! completed successfully"
    true
  rescue => e
    Rails.logger.error "💥 Error in partial_redeem!: #{e.class} - #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise
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
    active? && !expired? && remaining_balance > 0
  end

  def can_partial_redeem?(redemption_amount)
    active? && !expired? && remaining_balance >= redemption_amount && redemption_amount > 0
  end

  def total_redemptions
    transactions.successful.redemptions.sum(:amount)
  end

  def refund!(refund_amount:, reason:, actor:)
    transaction do
      lock!
      reload

      # Validate refund amount
      total_redeemed = transactions.successful.redemptions.sum(:amount)
      return false if refund_amount > total_redeemed
      return false if refund_amount <= 0

      # Create refund transaction
      transactions.create!(
        amount: refund_amount,
        txn_type: :refund,
        status: :succeeded,
        processor_ref: "refund_#{SecureRandom.uuid}",
        merchant: merchant,
        user: actor,
        currency: currency,
        metadata: {
          actor_id: actor.id,
          reason: reason,
          refunded_at: Time.current.iso8601
        }
      )

      # Restore balance
      update!(remaining_balance: remaining_balance + refund_amount)

      # Track owner activity for refund
      touch_owner_activity!

      # Revert to active if any balance is restored (or fully refunded)
      if redeemed? && remaining_balance.positive?
        update!(status: :active, redeemed_at: nil)
      elsif remaining_balance == amount
        update!(status: :active, redeemed_at: nil)
      end
    end

    true
  end

  def transfer_to!(new_recipient:, actor:)
    transaction do
      lock!
      reload

      # Validations
      return false unless active? && remaining_balance > 0
      return false unless new_recipient.is_a?(User)
      return false if new_recipient == recipient

      old_recipient = recipient

      # Create transfer transaction
      transactions.create!(
        amount: 0, # No money movement, just ownership change
        txn_type: :adjustment,
        status: :succeeded,
        processor_ref: "transfer_#{SecureRandom.uuid}",
        merchant: merchant,
        user: actor,
        currency: currency,
        metadata: {
          action: "transfer",
          from_user_id: old_recipient.id,
          to_user_id: new_recipient.id,
          actor_id: actor.id,
          transferred_at: Time.current.iso8601
        }
      )

      # Update recipient
      update!(recipient: new_recipient)

      # Track owner activity for transfer
      touch_owner_activity!

      # Send notification to new recipient
      send_notifications!
    end

    true
  end

  # Trigger notification delivery
  def send_notifications!
    return false unless recipient.present?

    SendGiftCardNotificationsJob.perform_later(id)
    true
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
end
