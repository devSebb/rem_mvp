class ResendNotificationJob < ApplicationJob
  queue_as :default

  # Sender-triggered resend. Unlike NotificationJob this ignores the
  # sent_via_* first-delivery flags (see Messaging::Notifier#resend_delivery);
  # throttling happens upstream in GiftCards::ResendDelivery.
  def perform(gift_card_id)
    gift_card = GiftCard.find_by(id: gift_card_id)
    return unless gift_card&.recipient

    Messaging::Notifier.new(gift_card).resend_delivery
  end
end
