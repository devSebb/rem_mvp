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

  def self.find_by_link_token(token)
    return nil if token.blank?
    
    gift_cards = where.not(link_token_digest: nil)
    gift_cards.find { |gc| gc.valid_link_token?(token) }
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

  # Security token methods
  def generate_delivery_tokens!
    # Generate secure random link token (32 bytes, urlsafe base64)
    raw_link_token = SecureRandom.urlsafe_base64(32)
    self.link_token_digest = BCrypt::Password.create(raw_link_token)
    self.link_token_expires_at = 7.days.from_now

    # Generate 6-digit OTP
    raw_otp = format('%06d', SecureRandom.random_number(1_000_000))
    self.otp_digest = BCrypt::Password.create(raw_otp)
    self.otp_expires_at = 1.hour.from_now

    save!
    
    { link: raw_link_token, otp: raw_otp }
  end

  def valid_link_token?(raw_token)
    return false if link_token_digest.blank? || link_token_expires_at.blank?
    return false if link_token_expires_at < Time.current
    
    BCrypt::Password.new(link_token_digest) == raw_token
  end

  def valid_otp?(raw_otp)
    return false if otp_digest.blank? || otp_expires_at.blank?
    return false if otp_expires_at < Time.current
    
    BCrypt::Password.new(otp_digest) == raw_otp
  end

  def consume_link_token!
    return false if link_token_digest.blank?
    
    update!(
      link_token_digest: nil,
      link_token_expires_at: nil
    )
    true
  end

  def consume_otp!
    return false if otp_digest.blank?
    
    update!(
      otp_digest: nil,
      otp_expires_at: nil
    )
    true
  end

  def redeem_url
    return nil if link_token_digest.blank?
    
    Rails.application.routes.url_helpers.redeem_url(token: link_token_digest)
  end

  # Trigger notification delivery
  def send_notifications!
    return false unless recipient.present?
    
    SendGiftCardNotificationsJob.perform_later(id)
    true
  end

  # DEVELOPMENT ONLY: Method to retrieve raw code for testing
  # TODO: Remove this method before production deployment
  def raw_code
    return nil unless Rails.env.development?
    
    # For development, we'll try to find the code by checking against known test codes
    # This is a temporary solution for testing purposes
    test_codes = ['REM-TEST-1234-5678', 'REM-TEST-ABCD-EFGH']
    test_codes.find { |code| BCrypt::Password.new(code_digest) == code }
  end

  private

  def set_defaults
    self.currency ||= 'USD'
    self.status ||= :active
    self.code_digest ||= BCrypt::Password.create(CodeGenerator.generate)
    self.remaining_balance = amount if amount.present? && remaining_balance == 0
  end
end
