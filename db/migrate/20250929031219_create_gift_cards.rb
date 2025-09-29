class CreateGiftCards < ActiveRecord::Migration[7.2]
  def change
    create_table :gift_cards do |t|
      t.references :sender, null: false, foreign_key: { to_table: :users }
      t.references :recipient, null: true, foreign_key: { to_table: :users }
      t.references :merchant, null: true, foreign_key: true
      t.integer :amount, null: false
      t.string :currency, default: 'USD', null: false
      t.string :code_digest, null: false
      t.integer :status, default: 0, null: false
      t.datetime :redeemed_at
      t.datetime :expires_at
      t.string :checkout_session_id

      t.timestamps
    end

    add_index :gift_cards, :status
    add_index :gift_cards, :code_digest, unique: true
    add_index :gift_cards, :checkout_session_id, unique: true
  end
end
