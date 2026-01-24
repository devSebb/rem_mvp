class AddNoteToGiftCards < ActiveRecord::Migration[7.2]
  def change
    add_column :gift_cards, :note, :text
  end
end
