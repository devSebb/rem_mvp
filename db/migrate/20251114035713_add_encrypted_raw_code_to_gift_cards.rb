class AddEncryptedRawCodeToGiftCards < ActiveRecord::Migration[7.2]
  def change
    add_column :gift_cards, :encrypted_raw_code, :text
    add_index :gift_cards, :encrypted_raw_code, where: "encrypted_raw_code IS NOT NULL"
  end
end
