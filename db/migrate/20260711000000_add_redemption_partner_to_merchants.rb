class AddRedemptionPartnerToMerchants < ActiveRecord::Migration[7.2]
  def change
    add_column :merchants, :partner_redemption, :boolean, default: false, null: false
    add_column :merchants, :redemption_partner_label, :string
    add_column :merchants, :coverage_text, :string
  end
end
