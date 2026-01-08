class AddAvatarUrlToMerchants < ActiveRecord::Migration[7.2]
  def change
    add_column :merchants, :avatar_url, :string
  end
end

