module Messaging
  # Sends a "your gift card was just redeemed" push notification to the
  # recipient (the gift card owner) after a successful merchant redemption.
  # Mirrors the existing Messaging::Notifier#send_push pattern but is decoupled
  # from the gift-card-creation workflow.
  class RedemptionPusher
    def self.call(...)
      new(...).call
    end

    def initialize(gift_card:, amount_cents:, merchant:)
      @gift_card = gift_card
      @amount_cents = amount_cents
      @merchant = merchant
    end

    def call
      recipient = @gift_card.recipient
      return { success: false, error: "No recipient" } unless recipient

      remaining_cents = @gift_card.reload.remaining_balance
      currency = @gift_card.currency
      merchant_name = @merchant&.store_name || "Papayal"
      amount_label = format_amount(@amount_cents, currency)
      remaining_label = format_amount(remaining_cents, currency)

      PushSender.new.send_to_user(
        recipient,
        title: "Canje en #{merchant_name}",
        body: "Canjeaste #{amount_label}. Saldo restante: #{remaining_label}.",
        data: {
          type: "gift_card_redeemed",
          gift_card_id: @gift_card.id.to_s
        }
      )
    rescue => e
      Rails.logger.error "[RedemptionPusher] Failed for gift_card_id=#{@gift_card&.id}: #{e.class} - #{e.message}"
      { success: false, error: e.message }
    end

    private

    def format_amount(cents, currency)
      return "-" if cents.nil?
      "#{currency} #{format("%.2f", cents / 100.0)}"
    end
  end
end
