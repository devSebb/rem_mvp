# Deploy-transition shim (RELOADABLE_CARD_PLAN.md §10.2e). Until Push B the
# webhook enqueued NotificationJob.perform_later(gift_card_id). Any such job
# still in Redis (default queue or the retry set) when the Phase 3 worker
# comes up lands here, and a card id must never be read as a load id — that
# would notify the wrong recipient with someone else's claim link. What the
# old job meant is "announce this card", i.e. deliver its first load.
#
# A card the old webhook created after ledger:backfill_missing_loads ran has
# no load yet; retry until the post-deploy backfill (§10.1 step 5) creates it.
# New code enqueues LoadNotificationJob directly. Delete this class in Phase 5.
class NotificationJob < ApplicationJob
  queue_as :default

  class LoadNotReady < StandardError; end
  retry_on LoadNotReady, wait: 5.minutes, attempts: 24

  def perform(gift_card_id, _legacy_raw_code = nil)
    card = GiftCard.find_by(id: gift_card_id)
    unless card
      Rails.logger.error "❌ NotificationJob (legacy): card #{gift_card_id} not found"
      return
    end

    load = card.first_load
    raise LoadNotReady, "card #{card.id} has no load yet (waiting for ledger:backfill_missing_loads)" unless load

    Rails.logger.info "↪️ NotificationJob (legacy card id #{card.id}) → LoadNotificationJob load #{load.id}"
    LoadNotificationJob.perform_now(load.id)
  end
end
