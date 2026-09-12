module Messaging
  # One money format for every user-facing string (§4.4: "$30.00").
  module Money
    def self.format(cents, currency: "USD")
      amount = Kernel.format("%.2f", cents.to_i / 100.0)
      currency.to_s.upcase == "USD" ? "$#{amount}" : "#{currency} #{amount}"
    end
  end
end
