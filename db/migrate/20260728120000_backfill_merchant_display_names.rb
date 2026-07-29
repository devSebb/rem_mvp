class BackfillMerchantDisplayNames < ActiveRecord::Migration[7.2]
  # `merchants.name` mirrors `store_name` (see Merchant#sync_display_name), but
  # until now the callback only filled it in when blank. Any merchant renamed
  # after creation kept its original name in this column, and the purchase
  # receipt printed that stale copy — e.g. a card bought at "Medicity" arrived
  # as "Farmacia Buendía". Realign the rows that drifted.
  #
  # Touches only rows that actually differ, and leaves `updated_at` alone: the
  # column is a derived duplicate, so bumping timestamps would misreport a
  # merchant edit to anything syncing on `updated_at`.
  def up
    drifted = select_all(<<~SQL).rows
      SELECT id, name, store_name
      FROM merchants
      WHERE store_name IS NOT NULL
        AND store_name <> ''
        AND name IS DISTINCT FROM store_name
      ORDER BY id
    SQL

    if drifted.empty?
      say "No merchants with a stale display name — nothing to backfill."
      return
    end

    drifted.each { |id, old_name, store_name| say "merchant ##{id}: #{old_name.inspect} -> #{store_name.inspect}", true }

    updated = execute(<<~SQL).cmd_tuples
      UPDATE merchants
      SET name = store_name
      WHERE store_name IS NOT NULL
        AND store_name <> ''
        AND name IS DISTINCT FROM store_name
    SQL

    say "Backfilled #{updated} merchant display name(s)."
  end

  def down
    # No-op: the overwritten values were stale duplicates of an older
    # `store_name`, not data worth restoring.
  end
end
