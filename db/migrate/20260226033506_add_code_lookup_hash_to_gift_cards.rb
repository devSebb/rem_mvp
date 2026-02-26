class AddCodeLookupHashToGiftCards < ActiveRecord::Migration[7.2]
  def change
    add_column :gift_cards, :code_lookup_hash, :string
    add_index :gift_cards,
              :code_lookup_hash,
              unique: true,
              where: "code_lookup_hash IS NOT NULL",
              name: "index_gift_cards_on_code_lookup_hash"
  end
end
