class AddClaimedAtToUsers < ActiveRecord::Migration[7.2]
  # Adds the "pending recipient" pattern: users who received a gift card
  # but haven't signed up themselves have claimed_at = nil. Real users
  # (signed up directly) have claimed_at set to their signup time.
  #
  # Existing users are backfilled as claimed UNLESS they were created via
  # the legacy random-fake-email path (gift_recipient_*@example.com),
  # which we now treat as pending so their real owners can claim them
  # at signup time.
  def up
    add_column :users, :claimed_at, :datetime
    add_index :users, :claimed_at

    # Backfill: anyone whose email is NOT a legacy fake gets claimed.
    # Legacy fakes (recipient-shells with no real email) stay pending.
    execute <<~SQL.squish
      UPDATE users
      SET claimed_at = created_at
      WHERE email NOT LIKE 'gift_recipient_%@example.com'
    SQL
  end

  def down
    remove_index :users, :claimed_at
    remove_column :users, :claimed_at
  end
end
