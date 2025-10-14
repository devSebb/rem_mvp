class GiftCard < ApplicationRecord
  belongs_to :sender, class_name: 'User'
  belongs_to :recipient, class_name: 'User', optional: true
  belongs_to :merchant, optional: true
  has_many :transactions, dependent: :destroy

  # Enums
  enum status: { active: 0, redeemed: 1, expired: 2, canceled: 3 }

  # Validations
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :remaining_balance, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :currency, presence: true
  validates :code_digest, presence: true, uniqueness: true
  validates :status, presence: true
  validates :link_token_digest, uniqueness: true, allow_nil: true
  validates :otp_digest, uniqueness: true, allow_nil: true

  # Callbacks
  before_validation :set_defaults, on: :create

  # Class methods
  def self.find_active_by_code(code)
    return nil if code.blank?
    
    gift_cards = where(status: :active)
    gift_cards.find { |gc| BCrypt::Password.new(gc.code_digest) == code }
  end


  # Instance methods
  def generate_code!
    raw_code = CodeGenerator.generate
    self.code_digest = BCrypt::Password.create(raw_code)
    save!
    raw_code
  end

  def redeem!(merchant:, actor:)
    partial_redeem!(redemption_amount: remaining_balance, merchant: merchant, actor: actor)
  end

  def partial_redeem!(redemption_amount:, merchant:, actor:)
    return false if merchant.nil? || actor.nil?

    transaction do
      # Pessimistic locking to prevent race conditions
      lock!
      reload # Get latest balance from database
      
      return false unless can_partial_redeem?(redemption_amount)

      # Create redemption transaction
      transactions.create!(
        amount: redemption_amount,
        txn_type: :redemption,
        status: :succeeded,
        processor_ref: "redeem_#{id}_#{Time.current.to_i}",
        metadata: {
          actor_id: actor.id,
          actor_type: actor.class.name,
          merchant_id: merchant.id,
          redeemed_at: Time.current.iso8601
        }
      )

      # Update remaining balance
      new_balance = remaining_balance - redemption_amount
      update!(
        remaining_balance: new_balance,
        merchant: merchant
      )

      # Mark as fully redeemed if balance is zero
      if new_balance == 0
        update!(
          status: :redeemed,
          redeemed_at: Time.current
        )
      end
    end

    true
  end

  def expired?
    expires_at.present? && expires_at < Time.current
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
        status: :pending,
        processor_ref: "refund_#{id}_#{Time.current.to_i}",
        metadata: {
          actor_id: actor.id,
          reason: reason,
          refunded_at: Time.current.iso8601
        }
      )
      
      # Restore balance
      update!(remaining_balance: remaining_balance + refund_amount)
      
      # Revert to active if fully refunded
      if remaining_balance == amount
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
        processor_ref: "transfer_#{id}_#{Time.current.to_i}",
        metadata: {
          action: 'transfer',
          from_user_id: old_recipient.id,
          to_user_id: new_recipient.id,
          actor_id: actor.id,
          transferred_at: Time.current.iso8601
        }
      )
      
      # Update recipient
      update!(recipient: new_recipient)
      
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
  def raw_code
    # This is a security risk - raw codes should not be stored in memory
    # For now, we'll generate a new code each time (not ideal for performance)
    # TODO: Implement secure token-based system in Phase 2
    generate_code!
  end

  private

  def set_defaults
    self.currency ||= 'USD'
    self.status ||= :active
    
    # Generate code and store digest
    if code_digest.blank?
      raw_code = CodeGenerator.generate
      self.code_digest = BCrypt::Password.create(raw_code)
    end
    
    self.remaining_balance = amount if amount.present? && remaining_balance == 0
  end
end
