class AddSecurityHoldAndDisputeToGiftCards < ActiveRecord::Migration[7.2]
  # Risk-scored security hold on gift cards:
  #   held_until    — if set and in the future, redemption is blocked
  #   risk_score    — cached from Stripe Charge#outcome#risk_score (0-99)
  #   risk_level    — cached from Stripe Charge#outcome#risk_level
  #                   ("normal" | "elevated" | "highest" | "not_assessed")
  #   disputed_at   — set when a Stripe dispute webhook lands; blocks further
  #                   redemption while a dispute is open
  #
  # Both held_until and disputed_at use partial indexes since lookups are
  # rare (admin queue + redemption guard only).
  def change
    add_column :gift_cards, :held_until, :datetime
    add_column :gift_cards, :risk_score, :integer
    add_column :gift_cards, :risk_level, :string
    add_column :gift_cards, :disputed_at, :datetime

    add_index :gift_cards, :held_until, where: "held_until IS NOT NULL"
    add_index :gift_cards, :disputed_at, where: "disputed_at IS NOT NULL"
  end
end
