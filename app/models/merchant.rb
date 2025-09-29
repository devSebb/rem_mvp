class Merchant < ApplicationRecord
  belongs_to :user
  has_many :gift_cards, dependent: :nullify
  has_many :transactions, through: :gift_cards
  has_many :settlements, dependent: :destroy

  validates :store_name, presence: true
  validates :contact_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
end
