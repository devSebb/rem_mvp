# Promote merchant redemption reversals (Type A refunds) from a metadata
# marker to a first-class column. Every money aggregate needs to net these
# out, and jsonb text-matching in eight call sites is how numbers drift.
# The partial unique index doubles as DB-level double-reversal protection.
class AddReversalOfTransactionIdToTransactions < ActiveRecord::Migration[7.2]
  def up
    add_column :transactions, :reversal_of_transaction_id, :bigint

    execute <<~SQL
      UPDATE transactions
      SET reversal_of_transaction_id = (metadata->>'refund_of_transaction_id')::bigint
      WHERE txn_type = 2
        AND metadata->>'refund_of_transaction_id' IS NOT NULL
    SQL

    add_index :transactions, :reversal_of_transaction_id,
              unique: true,
              where: "reversal_of_transaction_id IS NOT NULL",
              name: "index_transactions_on_reversal_of_txn_id"
  end

  def down
    remove_index :transactions, name: "index_transactions_on_reversal_of_txn_id"
    remove_column :transactions, :reversal_of_transaction_id
  end
end
