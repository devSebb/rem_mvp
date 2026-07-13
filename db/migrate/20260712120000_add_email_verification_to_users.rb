class AddEmailVerificationToUsers < ActiveRecord::Migration[7.2]
  # Email-verification columns for fresh signups. A new account is created
  # unverified (email_verified_at: nil) and cannot obtain auth tokens until
  # it confirms a 6-digit code emailed to the address. Only the SHA-256
  # digest of the code is stored — never the code itself. Mirrors the
  # existing claim_otp_* columns used for the pending-recipient claim flow.
  def up
    add_column :users, :email_verified_at, :datetime
    add_column :users, :email_otp_digest, :string
    add_column :users, :email_otp_sent_at, :datetime
    add_column :users, :email_otp_attempts, :integer, default: 0, null: false

    # Backfill: every account that already exists predates email
    # verification, so treat it as verified — otherwise the gate would lock
    # out the entire current user base on their next login.
    up_only do
      User.reset_column_information
      User.unscoped.where(email_verified_at: nil).update_all("email_verified_at = created_at")
    end
  end

  def down
    remove_column :users, :email_verified_at
    remove_column :users, :email_otp_digest
    remove_column :users, :email_otp_sent_at
    remove_column :users, :email_otp_attempts
  end
end
