class AddCheckoutKycFieldsToUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :address, :string
    add_column :users, :country_of_residence, :string
    add_column :users, :date_of_birth, :date
  end
end

