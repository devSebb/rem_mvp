module Messaging
  # Recipient pushes for load-level events that are not a delivery
  # (RELOADABLE_CARD_PLAN.md §4.4 "Notifications", §5.8):
  #   hold_released  — a Radar hold ended (timer or admin), funds spendable
  #   dispute_opened — a chargeback took one load out of spendable
  # Best effort: never raises into the caller.
  class LoadEventPusher
    def self.hold_released(load)
      new(load).hold_released
    end

    def self.dispute_opened(load)
      new(load).dispute_opened
    end

    def initialize(load)
      @load = load
      @card = load.gift_card
    end

    def hold_released
      push(
        title: "Tu saldo ya está disponible",
        body: "#{amount} en #{merchant} pasaron la revisión de seguridad.",
        type: "gift_card_hold_released"
      )
    end

    def dispute_opened
      push(
        title: "Una recarga está en revisión",
        body: "Una recarga de #{amount} está en revisión. El resto de tu saldo sigue disponible.",
        type: "gift_card_load_disputed"
      )
    end

    private

    def push(title:, body:, type:)
      recipient = @card&.recipient
      return { success: false, error: "No recipient" } unless recipient

      PushSender.new.send_to_user(
        recipient,
        title: title,
        body: body,
        data: { type: type, gift_card_id: @card.id.to_s, load_id: @load.id.to_s }
      )
    rescue => e
      Rails.logger.error "[LoadEventPusher] #{type} failed for load #{@load&.id}: #{e.class} - #{e.message}"
      { success: false, error: e.message }
    end

    def amount
      Money.format(@load.remaining_cents.positive? ? @load.remaining_cents : @load.amount_cents)
    end

    def merchant
      @card&.merchant&.store_name || "Papayal"
    end
  end
end
