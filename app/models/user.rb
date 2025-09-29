class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable

  # Enums
  enum role: { user: 0, merchant: 1, admin: 2 }

  # Associations
  has_one :merchant, dependent: :destroy
  has_many :sent_gift_cards, class_name: 'GiftCard', foreign_key: 'sender_id', dependent: :nullify
  has_many :received_gift_cards, class_name: 'GiftCard', foreign_key: 'recipient_id', dependent: :nullify

  # Validations
  validates :name, presence: true
  validates :phone, uniqueness: true, allow_blank: true
  validates :role, presence: true

  # Methods
  def merchant?
    role == 'merchant'
  end

  def admin?
    role == 'admin'
  end
end
