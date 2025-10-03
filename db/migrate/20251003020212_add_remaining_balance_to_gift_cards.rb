class AddRemainingBalanceToGiftCards < ActiveRecord::Migration[7.2]
  def change
    add_column :gift_cards, :remaining_balance, :integer, default: 0
    
    # Set remaining_balance to amount for existing gift cards
    reversible do |dir|
      dir.up do
        execute <<-SQL
          UPDATE gift_cards 
          SET remaining_balance = amount 
          WHERE status = 0
        SQL
      end
    end
  end
end
