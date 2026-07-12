class CreatePlatformSettings < ActiveRecord::Migration[7.2]
  def change
    create_table :platform_settings do |t|
      t.integer :buyer_fee_bps, default: 0, null: false
      t.integer :buyer_fee_fixed_cents, default: 0, null: false
      t.integer :merchant_commission_bps, default: 0, null: false
      t.boolean :purchases_enabled, default: true, null: false
      t.string :min_ios_version
      t.string :min_android_version
      t.references :updated_by, foreign_key: { to_table: :users }, null: true

      t.timestamps
    end
  end
end
