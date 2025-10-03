class AddSecurityFieldsToGiftCards < ActiveRecord::Migration[7.2]
  def change
    add_column :gift_cards, :link_token_digest, :string
    add_column :gift_cards, :link_token_expires_at, :datetime
    add_column :gift_cards, :otp_digest, :string
    add_column :gift_cards, :otp_expires_at, :datetime
    add_column :gift_cards, :sent_via_whatsapp, :boolean, default: false, null: false
    add_column :gift_cards, :sent_via_sms, :boolean, default: false, null: false
    add_column :gift_cards, :sent_via_email, :boolean, default: false, null: false
    
    add_index :gift_cards, :link_token_digest, unique: true
    add_index :gift_cards, :otp_digest, unique: true
  end
end
