# Reloadable gift cards — Phase 2 (RELOADABLE_CARD_PLAN.md §10 Phase 2 step 4).
#
# MUST run after `rake gift_cards:merge_duplicates` (and, in production,
# after `rake ledger:backfill_missing_loads` and `rake gift_cards:merchantless`)
# — see §10.1. It re-checks both preconditions and raises with the offending
# rows so a forgotten step fails the deploy instead of corrupting data.
#
#   1. UNIQUE (recipient_id, merchant_id) WHERE merged_into_id IS NULL  (I12)
#   2. gift_cards.merchant_id NOT NULL
#   3. payment_intent_id / checkout_session_id uniqueness moves to loads:
#      the card-level unique indexes become plain lookup indexes (legacy
#      readers keep working until Phase 5 drops the columns)
#   4. "Farmaenlace" redemption group seeded and assigned to the seven
#      launch merchants (§3.7, §5.6)
class ReloadableGiftCardsPhase2 < ActiveRecord::Migration[7.2]
  PAIR_INDEX = "index_gift_cards_on_recipient_merchant_unique".freeze

  def up
    assert_no_duplicate_pairs!
    assert_no_merchantless_cards!

    add_index :gift_cards, [:recipient_id, :merchant_id], unique: true,
              where: "merged_into_id IS NULL", name: PAIR_INDEX
    change_column_null :gift_cards, :merchant_id, false

    remove_index :gift_cards, name: "index_gift_cards_on_payment_intent_id"
    add_index :gift_cards, :payment_intent_id, where: "payment_intent_id IS NOT NULL"
    remove_index :gift_cards, name: "index_gift_cards_on_checkout_session_id"
    add_index :gift_cards, :checkout_session_id, where: "checkout_session_id IS NOT NULL"

    say_with_time "Seeding the Farmaenlace redemption group" do
      result = RedemptionGroups::SeedFarmaenlace.call
      if result[:skipped]
        say "skipped: #{result[:skipped]}", true
      else
        say "assigned #{result[:assigned].inspect}, already in group #{result[:already].inspect}" \
            "#{result[:by_id_fallback].any? ? ", matched by id fallback: #{result[:by_id_fallback].inspect}" : ''}", true
      end
    end
  end

  def down
    # Assignments made by the seed are undone; merchants an admin later put
    # in the group would come back out too, which is the honest inverse.
    if (group = RedemptionGroup.find_by(name: RedemptionGroups::SeedFarmaenlace::GROUP_NAME))
      Merchant.where(redemption_group_id: group.id).update_all(redemption_group_id: nil)
      group.destroy!
    end

    remove_index :gift_cards, :checkout_session_id
    add_index :gift_cards, :checkout_session_id, unique: true
    remove_index :gift_cards, :payment_intent_id
    add_index :gift_cards, :payment_intent_id, unique: true, where: "payment_intent_id IS NOT NULL"

    change_column_null :gift_cards, :merchant_id, true
    remove_index :gift_cards, name: PAIR_INDEX
  end

  private

  def assert_no_duplicate_pairs!
    dups = select_rows(<<~SQL)
      SELECT recipient_id, merchant_id, COUNT(*), array_agg(id ORDER BY id)
      FROM gift_cards
      WHERE merged_into_id IS NULL
      GROUP BY recipient_id, merchant_id
      HAVING COUNT(*) > 1
      ORDER BY recipient_id, merchant_id
    SQL
    return if dups.empty?

    raise ActiveRecord::MigrationError, <<~MSG
      #{dups.size} (recipient_id, merchant_id) pair(s) still have more than one non-merged gift card.
      Run `bin/rake gift_cards:merge_duplicates` (DRY_RUN=1 first) before this migration:
      #{dups.map { |r, m, n, ids| "  recipient #{r} × merchant #{m}: #{n} cards #{ids}" }.join("\n")}
    MSG
  end

  def assert_no_merchantless_cards!
    ids = select_values("SELECT id FROM gift_cards WHERE merchant_id IS NULL ORDER BY id")
    return if ids.empty?

    raise ActiveRecord::MigrationError,
          "#{ids.size} gift card(s) have no merchant: #{ids.inspect}. " \
          "Resolve them (assign a merchant, or `bin/rake gift_cards:merchantless:expire`) before this migration."
  end
end
