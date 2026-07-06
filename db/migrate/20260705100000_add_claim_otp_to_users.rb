class AddClaimOtpToUsers < ActiveRecord::Migration[7.2]
  # OTP columns for verifying that whoever signs up to claim a pending
  # recipient account (created when a gift card was sent to their email or
  # phone) actually controls that contact channel. Only the SHA-256 digest
  # of the 6-digit code is stored — never the code itself.
  def change
    add_column :users, :claim_otp_digest, :string
    add_column :users, :claim_otp_sent_at, :datetime
    add_column :users, :claim_otp_attempts, :integer, default: 0, null: false
  end
end
