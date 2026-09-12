# Phase 1 backfill (RELOADABLE_CARD_PLAN.md §10, Phase 1 step 2).
#
# For every gift card that has NO gift_card_loads row yet, create exactly one
# load copying the card's legacy columns, link the card's ledger rows to that
# load, write one allocation per redemption/reversal, and set the card's
# counter columns. Pure SQL, set-based, idempotent: cards that already have a
# load are never touched, so it is safe to re-run from
# `rake ledger:backfill_missing_loads` for cards minted by legacy code between
# the Phase 1 and Phase 3 deploys.
#
# Numbers are copied verbatim — nothing is invented. Where legacy code moved
# money without a ledger row (e.g. `gift_cards:cancel_fakes` zeroing a test
# card) the resulting load will not satisfy I2; Ledger::Verifier reports those
# separately so they can be reviewed rather than silently "fixed".
module Ledger
  module LegacyLoadBackfill
    SOURCE_STRIPE = 0
    SOURCE_ISSUANCE = 1

    STATUS_AVAILABLE = 0
    STATUS_HELD = 1
    STATUS_DISPUTED = 2
    STATUS_EXHAUSTED = 3
    STATUS_REFUNDED = 4
    STATUS_WRITTEN_OFF = 5

    CARD_STATUS_ACTIVE = 0
    CARD_STATUS_REDEEMED = 1
    CARD_STATUS_EXPIRED = 2

    TXN_PURCHASE = 0
    TXN_REDEMPTION = 1
    TXN_REFUND = 2
    TXN_ADJUSTMENT = 3
    TXN_ISSUANCE = 4
    TXN_SUCCEEDED = 1

    DIRECTION_DEBIT = 0
    DIRECTION_CREDIT = 1

    module_function

    # @return [Hash] counts of what was written
    def call(connection: ActiveRecord::Base.connection)
      connection.transaction do
        # Pin the working set first so every later statement agrees on which
        # cards are "legacy" even if a load is inserted concurrently. Dropped
        # explicitly (not just ON COMMIT) so repeated calls inside one outer
        # transaction — e.g. transactional specs — do not collide.
        connection.execute("DROP TABLE IF EXISTS legacy_backfill_cards")
        connection.execute(<<~SQL)
          CREATE TEMP TABLE legacy_backfill_cards ON COMMIT DROP AS
          SELECT gc.id
          FROM gift_cards gc
          WHERE NOT EXISTS (SELECT 1 FROM gift_card_loads l WHERE l.gift_card_id = gc.id)
        SQL

        cards = connection.select_value("SELECT COUNT(*) FROM legacy_backfill_cards").to_i
        result =
          if cards.zero?
            empty_result
          else
            loads = insert_loads(connection)
            linked = link_transactions(connection)
            allocations = insert_allocations(connection)
            update_card_counters(connection)
            remapped = remap_card_statuses(connection)
            backfill_user_dispute_counters(connection)

            { cards: cards, loads: loads, allocations: allocations,
              transactions_linked: linked, statuses_remapped: remapped }
          end

        # On failure the transaction (or savepoint) rollback removes the temp
        # table for us; on success drop it now rather than at commit.
        connection.execute("DROP TABLE IF EXISTS legacy_backfill_cards")
        result
      end
    end

    def empty_result
      { cards: 0, loads: 0, allocations: 0, transactions_linked: 0, statuses_remapped: 0 }
    end

    # One load per card. Type B refunds = succeeded refund rows on the card
    # with no reversal marker; write-offs = succeeded dispute adjustments.
    # Status is derived from the cents/timestamps (see GiftCardLoad#derived_status).
    def insert_loads(connection)
      connection.exec_update(<<~SQL)
        WITH agg AS (
          SELECT
            gc.id AS gift_card_id,
            COALESCE((SELECT SUM(t.amount) FROM transactions t
                      WHERE t.gift_card_id = gc.id AND t.txn_type = #{TXN_REFUND}
                        AND t.status = #{TXN_SUCCEEDED} AND t.reversal_of_transaction_id IS NULL), 0) AS refunded_cents,
            COALESCE((SELECT SUM(t.amount) FROM transactions t
                      WHERE t.gift_card_id = gc.id AND t.txn_type = #{TXN_ADJUSTMENT}
                        AND t.status = #{TXN_SUCCEEDED} AND t.processor_ref LIKE 'dispute\\_%'), 0) AS written_off_cents,
            (SELECT t.metadata->>'stripe_dispute_id' FROM transactions t
             WHERE t.gift_card_id = gc.id AND t.txn_type = #{TXN_ADJUSTMENT}
               AND t.status = #{TXN_SUCCEEDED} AND t.processor_ref LIKE 'dispute\\_%'
             ORDER BY t.created_at DESC LIMIT 1) AS dispute_id,
            EXISTS (SELECT 1 FROM transactions t
                    WHERE t.gift_card_id = gc.id AND t.txn_type = #{TXN_ADJUSTMENT}
                      AND t.status = #{TXN_SUCCEEDED} AND t.processor_ref LIKE 'dispute\\_%') AS dispute_lost,
            COALESCE((SELECT NULLIF(t.metadata->>'fee_cents', '')::integer FROM transactions t
                      WHERE t.gift_card_id = gc.id AND t.txn_type = #{TXN_PURCHASE}
                        AND t.status = #{TXN_SUCCEEDED}
                      ORDER BY t.created_at ASC LIMIT 1), 0) AS fee_cents
          FROM gift_cards gc
          WHERE gc.id IN (SELECT id FROM legacy_backfill_cards)
        ),
        rows AS (
          SELECT
            gc.id AS gift_card_id,
            gc.sender_id,
            CASE WHEN gc.payment_intent_id IS NOT NULL OR gc.checkout_session_id IS NOT NULL
                 THEN #{SOURCE_STRIPE} ELSE #{SOURCE_ISSUANCE} END AS source,
            gc.payment_intent_id,
            gc.checkout_session_id,
            COALESCE(gc.amount, 0) AS amount_cents,
            COALESCE(gc.remaining_balance, 0) AS remaining_cents,
            agg.refunded_cents,
            agg.written_off_cents,
            agg.fee_cents,
            gc.currency,
            gc.note,
            gc.risk_score,
            gc.risk_level,
            gc.held_until,
            gc.disputed_at,
            agg.dispute_id,
            CASE WHEN agg.dispute_lost THEN 'lost' ELSE NULL END AS dispute_outcome,
            gc.sent_via_whatsapp, gc.sent_via_sms, gc.sent_via_email, COALESCE(gc.sent_via_push, false) AS sent_via_push,
            gc.created_at, gc.updated_at
          FROM gift_cards gc
          JOIN agg ON agg.gift_card_id = gc.id
        )
        INSERT INTO gift_card_loads (
          gift_card_id, sender_id, source, payment_intent_id, checkout_session_id,
          amount_cents, remaining_cents, refunded_cents, written_off_cents, fee_cents,
          currency, note, risk_score, risk_level, held_until, disputed_at, dispute_id, dispute_outcome,
          status, sent_via_whatsapp, sent_via_sms, sent_via_email, sent_via_push,
          created_at, updated_at
        )
        SELECT
          gift_card_id, sender_id, source, payment_intent_id, checkout_session_id,
          amount_cents, remaining_cents, refunded_cents, written_off_cents, fee_cents,
          currency, note, risk_score, risk_level, held_until, disputed_at, dispute_id, dispute_outcome,
          CASE
            WHEN remaining_cents = 0 AND written_off_cents > 0 THEN #{STATUS_WRITTEN_OFF}
            WHEN remaining_cents = 0 AND refunded_cents > 0 THEN #{STATUS_REFUNDED}
            WHEN remaining_cents = 0 THEN #{STATUS_EXHAUSTED}
            WHEN disputed_at IS NOT NULL AND dispute_outcome IS NULL THEN #{STATUS_DISPUTED}
            WHEN held_until IS NOT NULL AND held_until > NOW() THEN #{STATUS_HELD}
            ELSE #{STATUS_AVAILABLE}
          END AS status,
          sent_via_whatsapp, sent_via_sms, sent_via_email, sent_via_push,
          created_at, updated_at
        FROM rows
      SQL
    end

    # purchase / issuance / Type B refund / dispute write-off rows point at the
    # card's single load. Redemptions and Type A reversals stay NULL and are
    # linked through redemption_allocations instead (§3.5).
    def link_transactions(connection)
      connection.exec_update(<<~SQL)
        UPDATE transactions t
        SET gift_card_load_id = l.id
        FROM gift_card_loads l
        WHERE l.gift_card_id = t.gift_card_id
          AND t.gift_card_id IN (SELECT id FROM legacy_backfill_cards)
          AND t.gift_card_load_id IS NULL
          AND (
            t.txn_type IN (#{TXN_PURCHASE}, #{TXN_ISSUANCE})
            OR (t.txn_type = #{TXN_REFUND} AND t.reversal_of_transaction_id IS NULL)
            OR (t.txn_type = #{TXN_ADJUSTMENT} AND t.processor_ref LIKE 'dispute\\_%')
          )
      SQL
    end

    # One debit allocation per succeeded redemption, one credit per succeeded
    # Type A reversal, all against the card's single load.
    def insert_allocations(connection)
      connection.exec_update(<<~SQL)
        INSERT INTO redemption_allocations (transaction_id, gift_card_load_id, amount_cents, direction, created_at, updated_at)
        SELECT t.id, l.id, t.amount,
               CASE WHEN t.txn_type = #{TXN_REDEMPTION} THEN #{DIRECTION_DEBIT} ELSE #{DIRECTION_CREDIT} END,
               t.created_at, t.created_at
        FROM transactions t
        JOIN gift_card_loads l ON l.gift_card_id = t.gift_card_id
        WHERE t.gift_card_id IN (SELECT id FROM legacy_backfill_cards)
          AND t.status = #{TXN_SUCCEEDED}
          AND t.amount > 0
          AND (
            t.txn_type = #{TXN_REDEMPTION}
            OR (t.txn_type = #{TXN_REFUND} AND t.reversal_of_transaction_id IS NOT NULL)
          )
          AND NOT EXISTS (SELECT 1 FROM redemption_allocations ra
                          WHERE ra.transaction_id = t.id AND ra.gift_card_load_id = l.id)
      SQL
    end

    def update_card_counters(connection)
      connection.exec_update(<<~SQL)
        UPDATE gift_cards gc
        SET total_loaded_cents = COALESCE(gc.amount, 0),
            loads_count = 1,
            last_loaded_at = gc.created_at
        WHERE gc.id IN (SELECT id FROM legacy_backfill_cards)
      SQL
    end

    # D3: no terminal `redeemed`; `expired` was never written. Both become active.
    def remap_card_statuses(connection)
      connection.exec_update(<<~SQL)
        UPDATE gift_cards
        SET status = #{CARD_STATUS_ACTIVE}
        WHERE id IN (SELECT id FROM legacy_backfill_cards)
          AND status IN (#{CARD_STATUS_REDEEMED}, #{CARD_STATUS_EXPIRED})
      SQL
    end

    # Recompute from all loads (not just the ones created in this run) so the
    # counters are always the truth of the loads table.
    def backfill_user_dispute_counters(connection)
      connection.exec_update(<<~SQL)
        UPDATE users u
        SET dispute_open_count = COALESCE(c.open_count, 0),
            dispute_lost_count = COALESCE(c.lost_count, 0)
        FROM (
          SELECT sender_id,
                 COUNT(*) FILTER (WHERE disputed_at IS NOT NULL AND dispute_outcome IS NULL) AS open_count,
                 COUNT(*) FILTER (WHERE dispute_outcome = 'lost') AS lost_count
          FROM gift_card_loads
          WHERE sender_id IS NOT NULL
          GROUP BY sender_id
        ) c
        WHERE c.sender_id = u.id
          AND (u.dispute_open_count <> COALESCE(c.open_count, 0) OR u.dispute_lost_count <> COALESCE(c.lost_count, 0))
      SQL
    end
  end
end
