class FixRemainingBalanceForExistingGiftCards < ActiveRecord::Migration[7.2]
  def up
    # Fix gift cards that have remaining_balance = 0 but should have remaining_balance = amount
    execute <<-SQL
      UPDATE gift_cards 
      SET remaining_balance = amount 
      WHERE remaining_balance = 0 AND status = 0
    SQL
  end

  def down
    # This migration is not reversible as we can't determine which cards had 0 balance originally
  end
end
