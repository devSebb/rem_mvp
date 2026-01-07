class MakeGiftCardsRecipientNotNull < ActiveRecord::Migration[7.2]
  class GiftCard < ActiveRecord::Base
    self.table_name = "gift_cards"
  end

  def up
    # Backfill legacy rows that might have been created without a recipient.
    # Fail-safe: default recipient to sender so every gift card always has a recipient.
    GiftCard.where(recipient_id: nil).update_all("recipient_id = sender_id")

    change_column_null :gift_cards, :recipient_id, false
  end

  def down
    change_column_null :gift_cards, :recipient_id, true
  end
end
