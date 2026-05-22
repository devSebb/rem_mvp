class AddDeletedAtToUsers < ActiveRecord::Migration[7.2]
  # Soft-delete column for account deletion. When set, the user row remains
  # so foreign keys on gift_cards (sender_id/recipient_id, both NOT NULL)
  # stay valid and the audit trail is preserved, but all PII is wiped by
  # Users::DeleteAccount and the account is unrecoverable.
  #
  # Partial index since lookups by deleted_at are rare (admin/audit only).
  # The hot path (User.active) stays cheap.
  def change
    add_column :users, :deleted_at, :datetime
    add_index :users, :deleted_at, where: "deleted_at IS NOT NULL"
  end
end
