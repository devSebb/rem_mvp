class UserSession < ApplicationRecord
  belongs_to :user
  # Set when refresh-token rotation retired this session (see Auth::RefreshTokens).
  belongs_to :replaced_by, class_name: "UserSession", optional: true

  scope :active, -> { where(revoked_at: nil) }

  validates :refresh_token_digest, presence: true

  def self.digest(token)
    Digest::SHA256.hexdigest(token.to_s)
  end

  def revoked?
    revoked_at.present?
  end
end
