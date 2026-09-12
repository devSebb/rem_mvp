# Links a redemption (debit) or a Type A reversal (credit) transaction to the
# load(s) it consumed / re-credited, in cents. RELOADABLE_CARD_PLAN.md §3.3.
# Written only inside the card lock alongside the transaction row (§6.2).
class RedemptionAllocation < ApplicationRecord
  # `transaction` is reserved by ActiveRecord, hence the association name;
  # the column stays `transaction_id` as in the plan.
  belongs_to :ledger_transaction, class_name: "Transaction", foreign_key: :transaction_id, inverse_of: :redemption_allocations
  belongs_to :gift_card_load

  enum direction: { debit: 0, credit: 1 }

  validates :amount_cents, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :direction, presence: true
  validates :gift_card_load_id, uniqueness: { scope: :transaction_id }
end
