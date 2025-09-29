class CreateMerchants < ActiveRecord::Migration[7.2]
  def change
    create_table :merchants do |t|
      t.references :user, null: false, foreign_key: true
      t.string :store_name, null: false
      t.text :address
      t.string :contact_email
      t.string :bank_account_iban

      t.timestamps
    end

    add_index :merchants, :store_name
  end
end
