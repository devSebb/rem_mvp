class AddInterestsToUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :interests, :string, array: true, default: []
  end
end
