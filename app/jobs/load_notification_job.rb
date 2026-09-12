# Delivers the recipient-facing notifications for ONE load (WhatsApp/SMS,
# email, push) — RELOADABLE_CARD_PLAN.md §5.9. Enqueued by Loads::Fulfill
# right after the load is credited. The argument is the gift_card_load id.
# (NotificationJob is the pre-Push-B card-id shim, see §10.2e.)
class LoadNotificationJob < ApplicationJob
  queue_as :default

  def perform(gift_card_load_id)
    load = GiftCardLoad.find(gift_card_load_id)

    unless load.gift_card&.recipient
      Rails.logger.error "❌ Load #{gift_card_load_id} has no recipient - cannot send notification"
      return
    end

    Rails.logger.info "📧 Sending notifications for load #{load.id} (card #{load.gift_card_id}) to #{load.gift_card.recipient.email}"

    notifier = Messaging::Notifier.new(load)
    results = notifier.send_all_notifications

    Rails.logger.info "✅ Load notifications sent for #{load.id}: #{results.inspect}"

    %i[email sms whatsapp push].each do |channel|
      next unless results[channel]

      if results[channel][:success]
        Rails.logger.info "   ✓ #{channel} sent successfully"
      else
        Rails.logger.warn "   ✗ #{channel} failed: #{results[channel][:error]}"
      end
    end

    results
  rescue ActiveRecord::RecordNotFound
    Rails.logger.error "❌ Load #{gift_card_load_id} not found for notification"
  rescue => e
    Rails.logger.error "💥 Failed to send notification for load #{gift_card_load_id}: #{e.class} - #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise
  end
end
