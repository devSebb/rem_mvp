class Merchant < ApplicationRecord
  include MerchantCategories

  attr_reader :generated_secret_key

  belongs_to :user
  has_many :gift_cards, dependent: :nullify
  has_many :transactions, through: :gift_cards
  has_many :settlements, dependent: :destroy
  has_one_attached :logo

  enum status: { active: 0, suspended: 1 }

  validates :store_name, presence: true
  validates :name, presence: true
  validates :public_key, presence: true, uniqueness: true
  validates :secret_key_digest, presence: true, uniqueness: true
  validates :contact_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validate :validate_logo

  before_validation :sync_display_name
  before_validation :ensure_api_keys

  def self.digest_secret(raw)
    return if raw.blank?

    Digest::SHA256.hexdigest(raw)
  end

  def self.generate_keys!(merchant)
    raw_secret = "sec_#{SecureRandom.hex(32)}"
    public_key = "pub_#{SecureRandom.hex(16)}"

    merchant.update!(
      public_key: public_key,
      secret_key_digest: digest_secret(raw_secret)
    )

    merchant.instance_variable_set(:@generated_secret_key, raw_secret)
    { public_key: public_key, secret_key: raw_secret }
  end

  def authenticate_secret(raw)
    return false if raw.blank? || secret_key_digest.blank?

    candidate = self.class.digest_secret(raw)
    return false if candidate.blank?

    ActiveSupport::SecurityUtils.secure_compare(secret_key_digest, candidate)
  end

  private

  def sync_display_name
    self.name = store_name if name.blank? && store_name.present?
  end

  def ensure_api_keys
    self.public_key ||= "pub_#{SecureRandom.hex(16)}"
    return if secret_key_digest.present?

    raw_secret = "sec_#{SecureRandom.hex(32)}"
    @generated_secret_key = raw_secret
    self.secret_key_digest = self.class.digest_secret(raw_secret)
  end

  def validate_logo
    return unless logo.attached?

    if logo.blob.byte_size > 5.megabytes
      errors.add(:logo, "is too large (max 5MB)")
    end

    return if logo.content_type&.start_with?("image/")

    errors.add(:logo, "must be an image")
  end
end
