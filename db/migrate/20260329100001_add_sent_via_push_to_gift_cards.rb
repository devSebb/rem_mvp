class AddSentViaPushToGiftCards < ActiveRecord::Migration[7.2]
  def change
    add_column :gift_cards, :sent_via_push, :boolean, default: false
  end
end
