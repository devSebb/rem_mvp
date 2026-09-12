# frozen_string_literal: true

# Money fixtures for the reloadable-card model. Specs must never move
# cents by poking `remaining_balance`; they go through the same allocator
# the app uses so every fixture satisfies the §7 invariants.
module LedgerHelpers
  # A succeeded redemption of `cents` by `merchant` drawn FIFO from the card's
  # spendable loads (allocations written). Returns the redemption Transaction.
  def redeem_card!(card, cents, merchant:, actor: nil, at: Time.current, processor_ref: nil)
    txn = nil
    card.with_lock do
      txn = Transaction.create!(
        gift_card: card, merchant: merchant, user: actor, amount: cents, txn_type: :redemption,
        status: :succeeded, currency: card.currency,
        processor_ref: processor_ref || "spec_redemption_#{SecureRandom.hex(6)}", created_at: at
      )
      Loads::Allocator.debit!(card: card, amount_cents: cents, transaction: txn)
    end
    card.reload
    txn
  end

  # A Stripe-funded load credited onto `card` with its purchase ledger row.
  def stripe_load!(card, cents, sender:, payment_intent_id: "pi_spec_#{SecureRandom.hex(4)}", at: Time.current, **attrs)
    load = nil
    card.with_lock do
      load = card.loads.create!({
        sender: sender, source: :stripe, payment_intent_id: payment_intent_id,
        amount_cents: cents, remaining_cents: cents, currency: card.currency, created_at: at
      }.merge(attrs))
      Transaction.create!(
        gift_card: card, gift_card_load: load, merchant: card.merchant, user: sender, amount: cents,
        txn_type: :purchase, status: :succeeded, currency: card.currency, processor_ref: payment_intent_id, created_at: at
      )
      GiftCard.where(id: card.id).update_all([
        "remaining_balance = remaining_balance + ?, total_loaded_cents = total_loaded_cents + ?, amount = COALESCE(amount, 0) + ?, last_loaded_at = ?",
        cents, cents, cents, at
      ])
    end
    card.reload
    load
  end
end

RSpec.configure do |config|
  config.include LedgerHelpers
end
