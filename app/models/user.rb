class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable

  # Enums
  enum role: { user: 0, merchant: 1, admin: 2 }
  enum preferred_channel: { whatsapp: 0, sms: 1 }, _prefix: :prefers

  attr_accessor :skip_national_id_validation
  attr_accessor :terms_accepted

  # Associations
  has_one :merchant, dependent: :destroy
  has_many :sent_gift_cards, class_name: 'GiftCard', foreign_key: 'sender_id', dependent: :nullify
  has_many :received_gift_cards, class_name: 'GiftCard', foreign_key: 'recipient_id', dependent: :nullify
  has_many :push_tokens, dependent: :destroy
  has_one_attached :avatar

  # Validations
  validates :first_name, :last_name, :email, :phone, presence: true
  validates :phone, uniqueness: true
  validates :role, presence: true
  validates :terms_accepted, acceptance: { message: "debes aceptar los términos y condiciones para registrarte" }, on: :create
  validates :national_id,
            format: {
              with: /\A[a-zA-Z0-9]{7,}\z/,
              message: "must be at least 7 alphanumeric characters"
            },
            allow_blank: true
  validate :validate_avatar
  with_options on: :checkout_kyc do
    validates :address, :country_of_residence, :date_of_birth, presence: true
  end

  before_validation :normalize_contact_fields
  before_validation :sync_name_fields
  before_validation :normalize_national_id

  # Methods
  def merchant?
    role == 'merchant'
  end

  def admin?
    role == 'admin'
  end

  def full_name
    [first_name, last_name].compact_blank.join(" ")
  end

  private

  def normalize_contact_fields
    self.first_name = first_name.to_s.strip.presence if has_attribute?(:first_name)
    self.last_name = last_name.to_s.strip.presence if has_attribute?(:last_name)
    self.name = name.to_s.strip.presence if has_attribute?(:name)
    self.address = address.to_s.strip.presence if has_attribute?(:address)
    self.country_of_residence = country_of_residence.to_s.strip.presence if has_attribute?(:country_of_residence)
    self.phone = phone.to_s.strip.presence if has_attribute?(:phone)
    self.email = email.to_s.strip.downcase if has_attribute?(:email) && email.present?
  end

  def sync_name_fields
    if first_name.blank? && last_name.blank? && name.present?
      self.first_name, self.last_name = split_name(name)
    end

    return unless first_name.present? || last_name.present?

    combined_name = [first_name, last_name].compact_blank.join(" ")
    self.name = combined_name if has_attribute?(:name)
  end

  def normalize_national_id
    return if national_id.blank?

    self.national_id = national_id.to_s.strip.gsub(/[\s-]+/, '').upcase
  end

  def split_name(full_name)
    parts = full_name.to_s.strip.split(/\s+/, 2)
    [parts.first, parts.second.to_s]
  end

  def validate_avatar
    return unless avatar.attached?

    if avatar.blob.byte_size > 5.megabytes
      errors.add(:avatar, "is too large (max 5MB)")
    end

    return if avatar.content_type&.start_with?("image/")

    errors.add(:avatar, "must be an image")
  end
end
