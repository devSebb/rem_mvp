class AddAuditFieldsToSettlements < ActiveRecord::Migration[7.2]
  # Adds the manual-payout audit trail. When an admin wires money to a
  # merchant and marks the settlement paid, we record who, when, the
  # payment method (wire/zelle/etc.), and the reference number for the
  # accounting trail.
  def change
    add_column :settlements, :paid_at, :datetime
    add_column :settlements, :paid_by_admin_id, :bigint
    add_column :settlements, :payment_method, :string
    add_column :settlements, :payment_reference, :string
    add_index :settlements, :paid_by_admin_id
  end
end
