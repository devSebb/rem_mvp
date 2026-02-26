class AddCompositeIndexesForPerformance < ActiveRecord::Migration[7.2]
  def change
    # Dashboard, settlements, and settlement service filter by merchant + txn_type + status + created_at
    add_index :transactions,
              %i[merchant_id txn_type status created_at],
              name: "index_transactions_on_merchant_txn_status_created"

    # Purchase limiter: sender + status + created_at (24h window)
    add_index :gift_cards,
              %i[sender_id status created_at],
              name: "index_gift_cards_on_sender_status_created"

    # Policy scope and API ordering: sender/recipient + updated_at + id
    add_index :gift_cards,
              %i[sender_id updated_at id],
              name: "index_gift_cards_on_sender_updated_id"
    add_index :gift_cards,
              %i[recipient_id updated_at id],
              name: "index_gift_cards_on_recipient_updated_id"
  end
end
