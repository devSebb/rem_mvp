class CreateSettlements < ActiveRecord::Migration[7.2]
  def change
    create_table :settlements do |t|
      t.references :merchant, null: false, foreign_key: true
      t.integer :amount, null: false
      t.integer :payout_status, default: 0, null: false
      t.date :period_start, null: false
      t.date :period_end, null: false
      t.text :notes

      t.timestamps
    end

    add_index :settlements, :payout_status
    add_index :settlements, [:period_start, :period_end]
  end
end
