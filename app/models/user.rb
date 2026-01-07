class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable

  # Enums
  enum role: { user: 0, merchant: 1, admin: 2 }

  attr_accessor :skip_national_id_validation

  # Associations
  has_one :merchant, dependent: :destroy
  has_many :sent_gift_cards, class_name: 'GiftCard', foreign_key: 'sender_id', dependent: :nullify
  has_many :received_gift_cards, class_name: 'GiftCard', foreign_key: 'recipient_id', dependent: :nullify

  # Validations
  validates :name, presence: true
  validates :phone, uniqueness: true, allow_blank: true
  validates :role, presence: true
  validates :national_id, presence: true, on: :create, unless: :skip_national_id_validation
  validates :national_id,
            format: {
              with: /\A[a-zA-Z0-9]{7,}\z/,
              message: "must be at least 7 alphanumeric characters"
            },
            allow_blank: true

  before_validation :normalize_national_id

  # Methods
  def merchant?
    role == 'merchant'
  end

  def admin?
    role == 'admin'
  end

  private

  def normalize_national_id
    return if national_id.nil?

    self.national_id = national_id.to_s.strip.gsub(/[\s-]+/, '').upcase
  end
end
