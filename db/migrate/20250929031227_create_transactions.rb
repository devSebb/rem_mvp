class CreateTransactions < ActiveRecord::Migration[7.2]
  def change
    create_table :transactions do |t|
      t.references :gift_card, null: false, foreign_key: true
      t.integer :amount, null: false
      t.integer :txn_type, null: false
      t.integer :status, default: 0, null: false
      t.string :processor_ref
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :transactions, :txn_type
    add_index :transactions, :status
    add_index :transactions, :metadata, using: :gin
  end
end
