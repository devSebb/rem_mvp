class AddCommissionToSettlements < ActiveRecord::Migration[7.2]
  def change
    # gross_amount stays nil on legacy settlements (created before commissions
    # existed); for those, amount was always the gross redemption sum.
    add_column :settlements, :gross_amount, :integer
    add_column :settlements, :commission_amount, :integer, default: 0, null: false
    add_column :settlements, :commission_bps, :integer, default: 0, null: false
  end
end
