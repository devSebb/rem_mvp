class NotificationJob < ApplicationJob
  queue_as :default

  def perform(gift_card_id, raw_code = nil)
    gift_card = GiftCard.find(gift_card_id)
    
    unless gift_card.recipient
      Rails.logger.error "❌ Gift card #{gift_card_id} has no recipient - cannot send notification"
      return
    end

    Rails.logger.info "📧 Sending notifications for gift card #{gift_card_id} to #{gift_card.recipient.email}"
    
    # Use the new messaging system
    notifier = Messaging::Notifier.new(gift_card)
    results = notifier.send_all_notifications
    
    Rails.logger.info "✅ Gift card notifications sent for #{gift_card_id}: #{results.inspect}"
    
    # Log which channels succeeded
    if results[:email]&.dig(:success)
      Rails.logger.info "   ✓ Email sent successfully"
    elsif results[:email]
      Rails.logger.warn "   ✗ Email failed: #{results[:email][:error]}"
    end
    
    if results[:sms]&.dig(:success)
      Rails.logger.info "   ✓ SMS sent successfully"
    elsif results[:sms]
      Rails.logger.warn "   ✗ SMS failed: #{results[:sms][:error]}"
    end
    
    if results[:whatsapp]&.dig(:success)
      Rails.logger.info "   ✓ WhatsApp sent successfully"
    elsif results[:whatsapp]
      Rails.logger.warn "   ✗ WhatsApp failed: #{results[:whatsapp][:error]}"
    end

    if results[:push]&.dig(:success)
      Rails.logger.info "   ✓ Push notification sent successfully"
    elsif results[:push]
      Rails.logger.warn "   ✗ Push failed: #{results[:push][:error]}"
    end
    
    results
  rescue ActiveRecord::RecordNotFound
    Rails.logger.error "❌ Gift card #{gift_card_id} not found for notification"
  rescue => e
    Rails.logger.error "💥 Failed to send notification for gift card #{gift_card_id}: #{e.class} - #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise
  end
end
