class LoadResendNotificationJob < ApplicationJob
  queue_as :default

  # Sender-triggered resend of ONE load's notification. Unlike
  # LoadNotificationJob this ignores the load's sent_via_* first-delivery
  # flags (see Messaging::Notifier#resend_delivery); throttling happens
  # upstream in GiftCards::ResendDelivery.
  def perform(gift_card_load_id)
    load = GiftCardLoad.find_by(id: gift_card_load_id)
    return unless load&.gift_card&.recipient

    Messaging::Notifier.new(load).resend_delivery
  end
end
