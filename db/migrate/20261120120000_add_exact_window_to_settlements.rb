# Settlements recorded only DATES, and their window ran to the end of
# period_end's day. A payout created at 10:00 therefore claimed every
# redemption made later that same day as "settled" although its amount
# (computed at 10:00) never included them: those merchants were never paid.
#
# This adds the exact window. Existing settlements are backfilled with their
# real cutoff, the moment they were created (when their amount was computed).
# Redemptions/reversals after that cutoff fall outside every window again, so
# they show up as unsettled and are paid in the merchant's next payout.
class AddExactWindowToSettlements < ActiveRecord::Migration[7.2]
  def up
    add_column :settlements, :period_start_at, :datetime
    add_column :settlements, :period_end_at, :datetime

    execute <<~SQL
      UPDATE settlements
      SET period_start_at = period_start::timestamp,
          period_end_at = created_at
      WHERE period_end_at IS NULL
    SQL

    change_column_null :settlements, :period_start_at, false
    change_column_null :settlements, :period_end_at, false
  end

  def down
    remove_column :settlements, :period_end_at
    remove_column :settlements, :period_start_at
  end
end
