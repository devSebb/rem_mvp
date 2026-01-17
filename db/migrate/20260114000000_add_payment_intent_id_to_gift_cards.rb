class AddPaymentIntentIdToGiftCards < ActiveRecord::Migration[7.2]
  def change
    add_column :gift_cards, :payment_intent_id, :string
    add_index :gift_cards, :payment_intent_id, unique: true, where: "payment_intent_id IS NOT NULL"
  end
end

