# Reloadable gift cards — Phase 1 (additive, safe to deploy with the old app).
# See RELOADABLE_CARD_PLAN.md §3, §10 (Phase 1) and §16.3.
#
# Adds the per-payment ledger (`gift_card_loads`), the redemption ↔ load link
# (`redemption_allocations`), redemption groups, the new card/user/transaction/
# platform_setting columns, then backfills exactly one load per existing card
# from the card's own columns and ledger rows. Nothing is dropped and no
# existing column changes meaning yet — Phase 3 switches behaviour, Phase 5
# drops the deprecated card columns.
#
# The backfill lives in Ledger::LegacyLoadBackfill (app/services) so it can be
# re-run idempotently from `rake ledger:backfill_missing_loads` for any card
# created by legacy code between this deploy and the Phase 3 deploy.
class ReloadableGiftCardsPhase1 < ActiveRecord::Migration[7.2]
  def up
    assert_no_duplicate_processor_refs!

    # ── 1. Redemption groups (D6) ──────────────────────────────────────
    create_table :redemption_groups do |t|
      t.string :name, null: false
      t.timestamps
    end
    add_index :redemption_groups, :name, unique: true
    add_reference :merchants, :redemption_group, foreign_key: true, index: true

    # ── 2. gift_cards: new columns, deprecated NOT NULLs relaxed ───────
    add_column :gift_cards, :total_loaded_cents, :integer, null: false, default: 0
    add_column :gift_cards, :frozen_at, :datetime
    add_column :gift_cards, :frozen_reason, :text
    add_column :gift_cards, :merged_into_id, :bigint
    add_column :gift_cards, :loads_count, :integer, null: false, default: 0
    add_column :gift_cards, :last_loaded_at, :datetime
    add_index :gift_cards, :merged_into_id, where: "merged_into_id IS NOT NULL"
    add_foreign_key :gift_cards, :gift_cards, column: :merged_into_id
    # Deprecated in §3.1; Phase 3 stops writing them. Relaxed here so Phase 3
    # code never fights a NOT NULL.
    change_column_null :gift_cards, :sender_id, true
    change_column_null :gift_cards, :amount, true

    # ── 3. gift_card_loads (§3.2) ──────────────────────────────────────
    create_table :gift_card_loads do |t|
      t.references :gift_card, null: false, foreign_key: true, index: false
      t.references :sender, foreign_key: { to_table: :users }, index: false
      t.integer :source, null: false, default: 0
      t.string :payment_intent_id
      t.string :checkout_session_id
      t.integer :amount_cents, null: false
      t.integer :remaining_cents, null: false
      t.integer :refunded_cents, null: false, default: 0
      t.integer :written_off_cents, null: false, default: 0
      t.integer :fee_cents, default: 0
      t.string :currency, null: false, default: "USD"
      t.text :note
      t.integer :risk_score
      t.string :risk_level
      t.datetime :held_until
      t.references :hold_released_by, foreign_key: { to_table: :users }, index: false
      t.datetime :disputed_at
      t.string :dispute_id
      t.string :dispute_outcome
      t.integer :status, null: false, default: 0
      t.boolean :sent_via_whatsapp, null: false, default: false
      t.boolean :sent_via_sms, null: false, default: false
      t.boolean :sent_via_email, null: false, default: false
      t.boolean :sent_via_push, null: false, default: false
      t.string :link_token_digest
      t.datetime :link_token_expires_at
      t.timestamps
    end
    add_index :gift_card_loads, [:gift_card_id, :created_at]
    add_index :gift_card_loads, [:sender_id, :created_at]
    add_index :gift_card_loads, :payment_intent_id, unique: true, where: "payment_intent_id IS NOT NULL"
    add_index :gift_card_loads, :checkout_session_id, unique: true, where: "checkout_session_id IS NOT NULL"
    add_index :gift_card_loads, :held_until, where: "held_until IS NOT NULL"
    add_index :gift_card_loads, :disputed_at, where: "disputed_at IS NOT NULL"
    add_index :gift_card_loads, :dispute_id, where: "dispute_id IS NOT NULL"
    add_index :gift_card_loads, :link_token_digest, unique: true, where: "link_token_digest IS NOT NULL"
    add_index :gift_card_loads, :status

    # ── 4. redemption_allocations (§3.3) ───────────────────────────────
    create_table :redemption_allocations do |t|
      t.references :transaction, null: false, foreign_key: true, index: false
      t.references :gift_card_load, null: false, foreign_key: true
      t.integer :amount_cents, null: false
      t.integer :direction, null: false, default: 0
      t.timestamps
    end
    add_index :redemption_allocations, [:transaction_id, :gift_card_load_id], unique: true,
              name: "index_redemption_allocations_on_txn_and_load"

    # ── 5. transactions (§3.5) ─────────────────────────────────────────
    add_reference :transactions, :gift_card_load, foreign_key: true, index: true
    add_index :transactions, :processor_ref, unique: true, where: "processor_ref IS NOT NULL"

    # ── 6. users: dispute counters (D4, I13) ───────────────────────────
    add_column :users, :dispute_open_count, :integer, null: false, default: 0
    add_column :users, :dispute_lost_count, :integer, null: false, default: 0
    add_column :users, :purchases_blocked_at, :datetime

    # ── 7. platform_settings: load caps (§3.6, launch values §4.1) ─────
    add_column :platform_settings, :max_load_cents, :integer, null: false, default: 20_000
    add_column :platform_settings, :max_loads_per_card_per_day, :integer, null: false, default: 2
    add_column :platform_settings, :max_daily_load_per_card_cents, :integer, null: false, default: 40_000
    add_column :platform_settings, :max_card_balance_cents, :integer, null: false, default: 50_000
    add_column :platform_settings, :max_daily_load_per_buyer_cents, :integer, null: false, default: 60_000
    add_column :platform_settings, :max_daily_loads_per_buyer, :integer, null: false, default: 3
    add_column :platform_settings, :max_30d_load_per_recipient_cents, :integer, null: false, default: 100_000
    add_column :platform_settings, :max_30d_load_per_buyer_cents, :integer, null: false, default: 200_000
    add_column :platform_settings, :buyer_refund_window_hours, :integer, null: false, default: 72

    # ── 8. Backfill: one load per existing card (§10 Phase 1 step 2) ───
    say_with_time "Backfilling gift_card_loads / redemption_allocations from legacy cards" do
      Ledger::LegacyLoadBackfill.call.tap do |result|
        say "cards processed: #{result[:cards]}, loads: #{result[:loads]}, " \
            "allocations: #{result[:allocations]}, txns linked: #{result[:transactions_linked]}, " \
            "statuses remapped: #{result[:statuses_remapped]}", true
      end
    end

    # ── 9. CHECK constraints (NOT VALID, then VALIDATE) ────────────────
    add_check_constraint :gift_cards, "remaining_balance >= 0",
                         name: "gift_cards_remaining_balance_non_negative", validate: false
    add_check_constraint :gift_cards, "total_loaded_cents >= COALESCE(remaining_balance, 0)",
                         name: "gift_cards_total_loaded_covers_remaining", validate: false
    add_check_constraint :gift_card_loads, "amount_cents > 0",
                         name: "gift_card_loads_amount_positive", validate: false
    add_check_constraint :gift_card_loads, "remaining_cents >= 0 AND remaining_cents <= amount_cents",
                         name: "gift_card_loads_remaining_within_amount", validate: false
    add_check_constraint :gift_card_loads, "refunded_cents >= 0 AND written_off_cents >= 0",
                         name: "gift_card_loads_refunded_written_off_non_negative", validate: false
    add_check_constraint :redemption_allocations, "amount_cents > 0",
                         name: "redemption_allocations_amount_positive", validate: false

    validate_check_constraint :gift_cards, name: "gift_cards_remaining_balance_non_negative"
    validate_check_constraint :gift_cards, name: "gift_cards_total_loaded_covers_remaining"
    validate_check_constraint :gift_card_loads, name: "gift_card_loads_amount_positive"
    validate_check_constraint :gift_card_loads, name: "gift_card_loads_remaining_within_amount"
    validate_check_constraint :gift_card_loads, name: "gift_card_loads_refunded_written_off_non_negative"
    validate_check_constraint :redemption_allocations, name: "redemption_allocations_amount_positive"
  end

  def down
    remove_check_constraint :redemption_allocations, name: "redemption_allocations_amount_positive"
    remove_check_constraint :gift_card_loads, name: "gift_card_loads_refunded_written_off_non_negative"
    remove_check_constraint :gift_card_loads, name: "gift_card_loads_remaining_within_amount"
    remove_check_constraint :gift_card_loads, name: "gift_card_loads_amount_positive"
    remove_check_constraint :gift_cards, name: "gift_cards_total_loaded_covers_remaining"
    remove_check_constraint :gift_cards, name: "gift_cards_remaining_balance_non_negative"

    # Undo the backfill's status remap so a rollback restores the legacy
    # "redeemed" marker the old code relies on (balance drained to zero by a
    # redemption ⇒ redeemed). Legacy rows whose status contradicted their own
    # balance (seed artifacts: `redeemed` with a full balance, `expired`,
    # which no code path ever wrote) are left `active`; nothing reads them.
    execute <<~SQL
      UPDATE gift_cards gc
      SET status = 1
      WHERE gc.status = 0
        AND COALESCE(gc.remaining_balance, 0) = 0
        AND COALESCE(gc.amount, 0) > 0
        AND (gc.redeemed_at IS NOT NULL
             OR EXISTS (SELECT 1 FROM transactions t
                        WHERE t.gift_card_id = gc.id AND t.txn_type = 1 AND t.status = 1))
    SQL

    remove_column :platform_settings, :buyer_refund_window_hours
    remove_column :platform_settings, :max_30d_load_per_buyer_cents
    remove_column :platform_settings, :max_30d_load_per_recipient_cents
    remove_column :platform_settings, :max_daily_loads_per_buyer
    remove_column :platform_settings, :max_daily_load_per_buyer_cents
    remove_column :platform_settings, :max_card_balance_cents
    remove_column :platform_settings, :max_daily_load_per_card_cents
    remove_column :platform_settings, :max_loads_per_card_per_day
    remove_column :platform_settings, :max_load_cents

    remove_column :users, :purchases_blocked_at
    remove_column :users, :dispute_lost_count
    remove_column :users, :dispute_open_count

    remove_index :transactions, :processor_ref
    remove_reference :transactions, :gift_card_load, foreign_key: true

    drop_table :redemption_allocations
    drop_table :gift_card_loads

    change_column_null :gift_cards, :amount, false
    change_column_null :gift_cards, :sender_id, false
    remove_foreign_key :gift_cards, column: :merged_into_id
    remove_index :gift_cards, :merged_into_id
    remove_column :gift_cards, :last_loaded_at
    remove_column :gift_cards, :loads_count
    remove_column :gift_cards, :merged_into_id
    remove_column :gift_cards, :frozen_reason
    remove_column :gift_cards, :frozen_at
    remove_column :gift_cards, :total_loaded_cents

    remove_reference :merchants, :redemption_group, foreign_key: true, index: true
    drop_table :redemption_groups
  end

  private

  # The unique index on processor_ref cannot be added while duplicates exist
  # (§16.5 stop condition). Fail loudly with the list instead of a bare PG error.
  def assert_no_duplicate_processor_refs!
    dups = select_rows(<<~SQL)
      SELECT processor_ref, COUNT(*)
      FROM transactions
      WHERE processor_ref IS NOT NULL
      GROUP BY processor_ref
      HAVING COUNT(*) > 1
    SQL
    return if dups.empty?

    raise ActiveRecord::MigrationError,
          "transactions.processor_ref has duplicates; resolve before migrating: " +
          dups.map { |ref, n| "#{ref} (x#{n})" }.join(", ")
  end
end
