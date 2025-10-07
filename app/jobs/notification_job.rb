class NotificationJob < ApplicationJob
  queue_as :default

  def perform(gift_card_id, raw_code)
    gift_card = GiftCard.find(gift_card_id)
    
    # Use the new messaging system
    notifier = Messaging::Notifier.new(gift_card)
    results = notifier.send_all_notifications
    
    Rails.logger.info "Gift card notifications sent for #{gift_card_id}: #{results}"
  rescue ActiveRecord::RecordNotFound
    Rails.logger.error "Gift card #{gift_card_id} not found for notification"
  rescue => e
    Rails.logger.error "Failed to send notification for gift card #{gift_card_id}: #{e.message}"
  end
end
