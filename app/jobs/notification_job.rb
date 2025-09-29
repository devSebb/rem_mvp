class NotificationJob < ApplicationJob
  queue_as :default

  def perform(gift_card_id, raw_code)
    gift_card = GiftCard.find(gift_card_id)
    NotificationSender.send_gift_card_notification(gift_card, raw_code)
  rescue ActiveRecord::RecordNotFound
    Rails.logger.error "Gift card #{gift_card_id} not found for notification"
  rescue => e
    Rails.logger.error "Failed to send notification for gift card #{gift_card_id}: #{e.message}"
  end
end
