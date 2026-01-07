class DropRedemptionsTable < ActiveRecord::Migration[7.2]
  def up
    drop_table :redemptions, if_exists: true
  end

  def down
    create_table :redemptions do |t|
      t.references :merchant, null: false, foreign_key: true
      t.references :gift_card, foreign_key: true
      t.references :redemption_token, foreign_key: true
      t.integer :amount_cents, null: false
      t.string :currency, null: false, default: "USD"
      t.integer :status, null: false
      t.string :decline_reason
      t.string :idempotency_key, null: false
      t.string :merchant_reference
      t.timestamps
    end

    add_index :redemptions, [:merchant_id, :idempotency_key], unique: true
  end
end
