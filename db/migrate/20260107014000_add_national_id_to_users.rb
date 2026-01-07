class AddNationalIdToUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :national_id, :string
    add_index :users, :national_id, unique: true
  end
end


