class AddCategoriesToMerchants < ActiveRecord::Migration[7.2]
  def change
    add_column :merchants, :categories, :string, array: true, default: []
  end
end
