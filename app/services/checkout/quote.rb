module Checkout
  # Server-authoritative price breakdown for a gift-card purchase: the app
  # must never compute fees client-side. subtotal = card face value,
  # total = what the buyer's card is charged.
  class Quote
    Result = Struct.new(
      :subtotal_cents, :fee_cents, :total_cents, :currency,
      :buyer_fee_bps, :buyer_fee_fixed_cents,
      keyword_init: true
    )

    def self.call(amount_cents:, currency: "USD", settings: PlatformSetting.current)
      fee_cents = settings.buyer_fee_cents_for(amount_cents)

      Result.new(
        subtotal_cents: amount_cents,
        fee_cents: fee_cents,
        total_cents: amount_cents + fee_cents,
        currency: currency.to_s.upcase,
        buyer_fee_bps: settings.buyer_fee_bps,
        buyer_fee_fixed_cents: settings.buyer_fee_fixed_cents
      )
    end
  end
end
