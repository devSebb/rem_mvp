# §8.1 GiftCard JSON for /me/gift_cards, /me/gift_cards/:id and
# by_payment_intent. Additive over the pre-reloadable shape so the app in
# the stores keeps working (D8, §10.2b) — the COMPAT fields must not be
# removed before Phase 5:
#   amount_cents            = total_loaded_cents
#   remaining_balance_cents = total remaining incl. held/disputed
#   held_until              = earliest hold among held loads, else nil
#   sender / sender_id      = latest load's sender
#   note                    = latest load's note
#   status                  = "frozen" for frozen_by_admin (enum key differs, §10.2a)
class GiftCardSerializer
  MAX_INLINE_LOADS = 20

  # @param attachment_url [#call] resolves an ActiveStorage attachment to a URL (nil-safe)
  def initialize(card, attachment_url:)
    @card = card
    @attachment_url = attachment_url
  end

  def self.call(card, attachment_url:)
    new(card, attachment_url: attachment_url).as_json
  end

  def as_json
    balances = card.balances
    loads = card.loads.reject(&:status_canceled?)
    latest = loads.max_by { |l| [l.created_at, l.id] }
    merchant_logo_url = attachment_url.call(card.merchant&.logo)

    {
      id: card.id,
      # COMPAT
      amount_cents: card.total_loaded_cents.to_i,
      remaining_balance_cents: balances[:remaining_balance],
      # NEW
      spendable_cents: balances[:spendable_cents],
      held_cents: balances[:held_cents],
      disputed_cents: balances[:disputed_cents],
      total_loaded_cents: card.total_loaded_cents.to_i,
      loads_count: card.loads_count.to_i,
      last_loaded_at: card.last_loaded_at&.iso8601,
      currency: card.currency,
      status: public_status,
      frozen_reason: card.frozen_by_admin? ? card.frozen_reason : nil,
      created_at: card.created_at&.iso8601,
      updated_at: card.updated_at&.iso8601,
      # COMPAT: the latest load's buyer
      sender_id: latest&.sender_id || card.sender_id,
      recipient_id: card.recipient_id,
      merchant_id: card.merchant_id,
      merchant: card.merchant ? { id: card.merchant.id, store_name: card.merchant.store_name, logo_url: merchant_logo_url } : nil,
      store_name: card.merchant&.store_name,
      merchant_name: card.merchant&.store_name,
      merchant_store_name: card.merchant&.store_name,
      merchant_logo_url: merchant_logo_url,
      note: latest ? latest.note : card.note,
      sender: serialize_sender(latest ? latest.sender : card.sender),
      # COMPAT: only while a hold is still in the future
      held_until: balances[:held_until]&.iso8601,
      loads: loads.sort_by { |l| [-l.created_at.to_f, -l.id] }.first(MAX_INLINE_LOADS).map { |l| serialize_load(l) }
    }
  end

  def serialize_load(load)
    {
      id: load.id,
      amount_cents: load.amount_cents,
      remaining_cents: load.remaining_cents,
      refunded_cents: load.refunded_cents,
      written_off_cents: load.written_off_cents,
      sender_id: load.sender_id,
      sender: serialize_sender(load.sender),
      note: load.note,
      status: load.derived_status.to_s,
      held_until: load.held? ? load.held_until.iso8601 : nil,
      disputed_at: load.dispute_open? ? load.disputed_at.iso8601 : nil,
      created_at: load.created_at&.iso8601,
      is_self: load.sender_id.present? && load.sender_id == card.recipient_id
    }
  end

  private

  attr_reader :card, :attachment_url

  def public_status
    return "frozen" if card.frozen_by_admin?
    return "active" if card.redeemed? || card.expired?

    card.status
  end

  def serialize_sender(sender)
    return nil unless sender

    {
      id: sender.id,
      name: sender.first_name,
      last_name: sender.last_name,
      full_name: sender.full_name.presence,
      email: sender.email,
      avatar_url: attachment_url.call(sender.avatar)
    }
  end
end
