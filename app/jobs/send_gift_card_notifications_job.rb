class SendGiftCardNotificationsJob < ApplicationJob
  queue_as :default

  def perform(gift_card_id)
    gift_card = GiftCard.find(gift_card_id)
    
    # Ensure we have a recipient
    unless gift_card.recipient
      Rails.logger.error "GiftCard #{gift_card_id} has no recipient"
      return
    end

    # Send notifications via all available channels
    notifier = Messaging::Notifier.new(gift_card)
    results = notifier.send_all_notifications

    # Log results
    Rails.logger.info "Gift card notifications sent for #{gift_card_id}: #{results}"

    # If all notifications failed, we might want to retry or alert
    if results.values.none? { |result| result[:success] }
      Rails.logger.error "All notification attempts failed for gift card #{gift_card_id}"
      # Could implement retry logic or admin notification here
    end

    results
  rescue ActiveRecord::RecordNotFound
    Rails.logger.error "GiftCard #{gift_card_id} not found"
  rescue => e
    Rails.logger.error "Failed to send gift card notifications for #{gift_card_id}: #{e.message}"
    raise e
  end
end
