class GiftCard < ApplicationRecord
  belongs_to :sender, class_name: 'User'
  belongs_to :recipient, class_name: 'User', optional: true
  belongs_to :merchant, optional: true
  has_many :transactions, dependent: :destroy

  # Enums
  enum status: { active: 0, redeemed: 1, expired: 2, canceled: 3 }

  # Validations
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :currency, presence: true
  validates :code_digest, presence: true, uniqueness: true
  validates :status, presence: true

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
    return false unless active?
    return false if merchant.nil? || actor.nil?

    transaction do
      update!(
        status: :redeemed,
        redeemed_at: Time.current,
        merchant: merchant
      )

      # Create redemption transaction
      transactions.create!(
        amount: amount,
        txn_type: :redemption,
        status: :succeeded,
        processor_ref: "redeem_#{id}_#{Time.current.to_i}",
        metadata: {
          actor_id: actor.id,
          actor_type: actor.class.name,
          merchant_id: merchant.id,
          redeemed_at: redeemed_at.iso8601
        }
      )
    end

    true
  end

  def expired?
    expires_at.present? && expires_at < Time.current
  end

  def can_be_redeemed?
    active? && !expired?
  end

  private

  def set_defaults
    self.currency ||= 'USD'
    self.status ||= :active
  end
end
