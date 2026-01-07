class UserSession < ApplicationRecord
  belongs_to :user

  scope :active, -> { where(revoked_at: nil) }

  validates :refresh_token_digest, presence: true

  def self.digest(token)
    Digest::SHA256.hexdigest(token.to_s)
  end

  def revoked?
    revoked_at.present?
  end
end

