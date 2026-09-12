# Deploy-transition shim, same reason as NotificationJob (§10.2e): jobs
# enqueued by the pre-Push-B code carry a gift card id. Resend the card's
# first load (pre-reloadable cards have exactly one). Delete in Phase 5.
class ResendNotificationJob < ApplicationJob
  queue_as :default

  def perform(gift_card_id)
    load = GiftCard.find_by(id: gift_card_id)&.first_load
    return unless load

    LoadResendNotificationJob.perform_now(load.id)
  end
end
