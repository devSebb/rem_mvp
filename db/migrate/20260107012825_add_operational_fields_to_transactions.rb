class AddOperationalFieldsToTransactions < ActiveRecord::Migration[7.2]
  def up
    # Allow storing declined redemption attempts (e.g. invalid token) where there is no gift_card.
    change_column_null :transactions, :gift_card_id, true

    # Normalized operational fields (nullable for backfill + optionality across txn types)
    add_reference :transactions, :merchant, null: true, foreign_key: true
    add_reference :transactions, :user, null: true, foreign_key: true # actor (cashier / merchant owner)
    add_reference :transactions, :redemption_token, null: true, foreign_key: true

    add_column :transactions, :currency, :string
    add_column :transactions, :idempotency_key, :string
    add_column :transactions, :decline_reason, :string
    add_column :transactions, :merchant_reference, :string

    add_index :transactions, [:merchant_id, :idempotency_key],
              unique: true,
              where: "idempotency_key IS NOT NULL"
  end

  def down
    remove_index :transactions, [:merchant_id, :idempotency_key] if index_exists?(:transactions, [:merchant_id, :idempotency_key])

    remove_column :transactions, :merchant_reference
    remove_column :transactions, :decline_reason
    remove_column :transactions, :idempotency_key
    remove_column :transactions, :currency

    remove_reference :transactions, :redemption_token, foreign_key: true
    remove_reference :transactions, :user, foreign_key: true
    remove_reference :transactions, :merchant, foreign_key: true

    change_column_null :transactions, :gift_card_id, false
  end
end
