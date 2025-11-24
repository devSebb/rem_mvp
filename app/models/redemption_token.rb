class RedemptionToken < ApplicationRecord

  TTL_SECONDS = 90



  belongs_to :gift_card



  scope :active, -> { where("expires_at > ? AND used_at IS NULL", Time.current) }



  validates :token_digest, presence: true

  validates :expires_at, presence: true



  def self.digest(raw)

    Digest::SHA256.hexdigest(raw)

  end

end

