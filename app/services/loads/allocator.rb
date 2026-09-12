# Moves cents between a card's loads and its ledger rows (§5.4, §5.5).
# Every method here MUST be called inside `card.with_lock` by the caller
# (§6.1 lock order: token → card → loads); the allocator never locks.
#
#   debit!(card:, amount_cents:, transaction:)
#     FIFO over spendable loads (oldest first): decrement each load,
#     write one debit allocation per load touched, decrement the card.
#
#   credit_reversal!(card:, reversal:, redemption:)
#     Put a redemption's cents back on exactly the loads it debited, capped
#     at what each load can still hold; any shortfall (the load was refunded
#     or written off since) becomes a new admin_adjustment load and is
#     reported so an admin sees the out-of-order money.
module Loads
  module Allocator
    class InsufficientSpendable < StandardError
      attr_reader :spendable_cents

      def initialize(spendable_cents)
        @spendable_cents = spendable_cents
        super("only #{spendable_cents} cents spendable")
      end
    end

    Debit = Struct.new(:load, :cents, keyword_init: true)
    Credit = Struct.new(:load, :cents, :shortfall_load, keyword_init: true)

    module_function

    # @return [Array<Debit>] the loads consumed and how much from each
    def debit!(card:, amount_cents:, transaction:)
      amount = amount_cents.to_i
      raise ArgumentError, "amount must be positive" unless amount.positive?

      loads = GiftCardLoad.where(gift_card_id: card.id).spendable.fifo.to_a
      spendable = loads.sum(&:remaining_cents)
      raise InsufficientSpendable, spendable if amount > spendable

      left = amount
      debits = []
      loads.each do |load|
        break if left.zero?

        take = [left, load.remaining_cents].min
        GiftCardLoad.where(id: load.id).update_all(["remaining_cents = remaining_cents - ?, updated_at = ?", take, Time.current])
        RedemptionAllocation.create!(ledger_transaction: transaction, gift_card_load: load, amount_cents: take, direction: :debit)
        load.reload.sync_status!
        debits << Debit.new(load: load, cents: take)
        left -= take
      end

      GiftCard.where(id: card.id).update_all(["remaining_balance = remaining_balance - ?, updated_at = ?", amount, Time.current])
      card.reload
      debits
    end

    # @return [Array<Credit>] one entry per debited load; `shortfall_load` is
    #   the admin_adjustment load created when the original load could not
    #   take all of its cents back
    def credit_reversal!(card:, reversal:, redemption:)
      debits = RedemptionAllocation.debit.where(transaction_id: redemption.id).includes(:gift_card_load).to_a
      raise ArgumentError, "redemption #{redemption.id} has no debit allocations" if debits.empty?

      credits = []
      total = 0
      debits.each do |alloc|
        load = alloc.gift_card_load.reload
        cap = load.amount_cents - load.refunded_cents - load.written_off_cents - load.remaining_cents
        restore = [[alloc.amount_cents, cap].min, 0].max
        shortfall = alloc.amount_cents - restore

        if restore.positive?
          GiftCardLoad.where(id: load.id).update_all(["remaining_cents = remaining_cents + ?, updated_at = ?", restore, Time.current])
          RedemptionAllocation.create!(ledger_transaction: reversal, gift_card_load: load, amount_cents: restore, direction: :credit)
          load.reload.sync_status!
        end

        shortfall_load = nil
        if shortfall.positive?
          shortfall_load = card.loads.create!(
            sender: nil, source: :admin_adjustment, amount_cents: shortfall, remaining_cents: shortfall,
            currency: card.currency,
            note: "Reversa del canje ##{redemption.id}: la recarga ##{load.id} ya había sido reembolsada/anulada"
          )
          # Funded by an issuance row (so I2 holds on the new load); the reversal
          # records the shortfall in its metadata and Ledger::Verifier counts it
          # toward I5 instead of a credit allocation.
          Transaction.create!(
            gift_card: card, gift_card_load: shortfall_load, merchant: reversal.merchant, user: reversal.user,
            amount: shortfall, currency: card.currency, txn_type: :issuance, status: :succeeded,
            processor_ref: "adjustment_#{SecureRandom.uuid}",
            metadata: { source: "reversal_shortfall", reversal_transaction_id: reversal.id,
                        redemption_transaction_id: redemption.id, original_load_id: load.id }
          )
          GiftCard.where(id: card.id).update_all(["total_loaded_cents = total_loaded_cents + ?, amount = COALESCE(amount, 0) + ?, last_loaded_at = ?", shortfall, shortfall, Time.current])
          Rails.logger.warn "[Allocator] reversal #{reversal.id}: load #{load.id} short by #{shortfall}; created adjustment load #{shortfall_load.id}"
        end

        total += alloc.amount_cents
        credits << Credit.new(load: load, cents: restore, shortfall_load: shortfall_load)
      end

      GiftCard.where(id: card.id).update_all(["remaining_balance = remaining_balance + ?, updated_at = ?", total, Time.current])

      # The reversal row records what it could not put back on the original
      # loads; Ledger::Verifier counts it toward I5 (credit allocs + shortfall
      # == reversal amount) and Refunds::Issue alerts the admin.
      shortfalls = credits.select(&:shortfall_load)
      if shortfalls.any?
        reversal.update!(metadata: (reversal.metadata || {}).merge(
          "shortfall_cents" => shortfalls.sum { |c| c.shortfall_load.amount_cents },
          "shortfall_load_ids" => shortfalls.map { |c| c.shortfall_load.id }
        ))
      end

      card.reload
      credits
    end
  end
end
