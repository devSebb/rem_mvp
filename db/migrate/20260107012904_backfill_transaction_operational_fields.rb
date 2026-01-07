class BackfillTransactionOperationalFields < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def up
    # 1) Backfill currency, merchant_id, user_id from gift_cards and transaction.metadata
    execute <<~SQL
      UPDATE transactions t
      SET currency = COALESCE(NULLIF(t.currency, ''), gc.currency, 'USD')
      FROM gift_cards gc
      WHERE t.gift_card_id = gc.id;
    SQL

    # Prefer explicit merchant_id from metadata; otherwise use gift card merchant_id.
    execute <<~SQL
      UPDATE transactions t
      SET merchant_id = COALESCE(
        NULLIF((t.metadata->>'merchant_id')::bigint, 0),
        gc.merchant_id,
        t.merchant_id
      )
      FROM gift_cards gc
      WHERE t.gift_card_id = gc.id
        AND t.merchant_id IS NULL;
    SQL

    # Prefer explicit actor_id from metadata (UI redemptions); otherwise, for purchases set actor to sender.
    execute <<~SQL
      UPDATE transactions t
      SET user_id = NULLIF((t.metadata->>'actor_id')::bigint, 0)
      WHERE t.user_id IS NULL
        AND (t.metadata ? 'actor_id');
    SQL

    execute <<~SQL
      UPDATE transactions t
      SET user_id = gc.sender_id
      FROM gift_cards gc
      WHERE t.user_id IS NULL
        AND t.gift_card_id = gc.id
        AND t.txn_type = 0; -- purchase
    SQL

    # 2) Backfill API redemption fields from redemptions table while it still exists.
    # API-created transactions store redemption_id in metadata; join to populate idempotency_key, merchant_reference, redemption_token_id.
    execute <<~SQL
      UPDATE transactions t
      SET idempotency_key = r.idempotency_key,
          merchant_reference = r.merchant_reference,
          decline_reason = CASE WHEN r.status = 1 THEN r.decline_reason ELSE NULL END,
          redemption_token_id = r.redemption_token_id,
          merchant_id = COALESCE(t.merchant_id, r.merchant_id),
          currency = COALESCE(NULLIF(t.currency, ''), r.currency, 'USD')
      FROM redemptions r
      WHERE t.idempotency_key IS NULL
        AND (t.metadata ? 'redemption_id')
        AND (t.metadata->>'redemption_id')::bigint = r.id;
    SQL
  end

  def down
    # Best-effort rollback (do not attempt to restore metadata)
    execute <<~SQL
      UPDATE transactions
      SET merchant_id = NULL,
          user_id = NULL,
          redemption_token_id = NULL,
          currency = NULL,
          idempotency_key = NULL,
          decline_reason = NULL,
          merchant_reference = NULL;
    SQL
  end
end
