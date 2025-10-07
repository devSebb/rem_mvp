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
    store_raw_code!(raw_code)
    save!
    raw_code
  end

  def redeem!(merchant:, actor:)
    partial_redeem!(redemption_amount: remaining_balance, merchant: merchant, actor: actor)
  end

  def partial_redeem!(redemption_amount:, merchant:, actor:)
    return false unless can_partial_redeem?(redemption_amount)
    return false if merchant.nil? || actor.nil?

    transaction do
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


  # Trigger notification delivery
  def send_notifications!
    return false unless recipient.present?
    
    SendGiftCardNotificationsJob.perform_later(id)
    true
  end

  # Method to get or generate raw code for notifications
  def raw_code
    # If we have a stored raw code, return it
    return @stored_raw_code if @stored_raw_code.present?
    
    # Otherwise, generate a new one
    generate_code!
  end

  # Store raw code temporarily (for notifications)
  def store_raw_code!(raw_code)
    @stored_raw_code = raw_code
  end

  private

  def set_defaults
    self.currency ||= 'USD'
    self.status ||= :active
    
    # Generate code and store both digest and raw code
    if code_digest.blank?
      raw_code = CodeGenerator.generate
      self.code_digest = BCrypt::Password.create(raw_code)
      store_raw_code!(raw_code)
    end
    
    self.remaining_balance = amount if amount.present? && remaining_balance == 0
  end
end
