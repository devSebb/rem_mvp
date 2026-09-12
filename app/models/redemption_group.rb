# A contractually affiliated set of merchants that may redeem each other's
# cards (RELOADABLE_CARD_PLAN.md §3.7, D6). Today: "Farmaenlace" (seeded in
# Phase 2). A merchant with no group may redeem only its own cards.
class RedemptionGroup < ApplicationRecord
  has_many :merchants, dependent: :nullify

  validates :name, presence: true, uniqueness: true
end
