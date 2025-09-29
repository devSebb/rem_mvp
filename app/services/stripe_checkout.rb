class StripeCheckout
  def self.create_session(amount_cents:, currency:, metadata: {})
    Stripe::Checkout::Session.create({
      payment_method_types: ['card'],
      line_items: [{
        price_data: {
          currency: currency,
          product_data: {
            name: 'Gift Card',
            description: "Gift card worth #{format_amount(amount_cents, currency)}"
          },
          unit_amount: amount_cents
        },
        quantity: 1
      }],
      mode: 'payment',
      success_url: "#{ENV['APP_HOST']}/gift_cards/success?session_id={CHECKOUT_SESSION_ID}",
      cancel_url: "#{ENV['APP_HOST']}/gift_cards/cancel",
      metadata: metadata
    })
  end

  private

  def self.format_amount(amount_cents, currency)
    case currency.upcase
    when 'USD'
      "$#{amount_cents / 100.0}"
    when 'EUR'
      "€#{amount_cents / 100.0}"
    else
      "#{amount_cents / 100.0} #{currency}"
    end
  end
end
