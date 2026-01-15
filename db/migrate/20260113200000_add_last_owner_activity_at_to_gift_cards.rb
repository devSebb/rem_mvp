class AddLastOwnerActivityAtToGiftCards < ActiveRecord::Migration[7.2]
  def change
    add_column :gift_cards, :last_owner_activity_at, :datetime, null: true
    add_index :gift_cards, :last_owner_activity_at
  end
end

