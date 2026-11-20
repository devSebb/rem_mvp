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
#
# Viewer-aware. GiftCardPolicy::Scope lets a user see any card they ever
# loaded, but the card belongs to its recipient: a buyer who is NOT the
# recipient gets a "sender view" with only their own loads and no balances,
# held/disputed amounts, freeze reason, or other buyers' loads/notes (§8.2:
# "a sender sees only the loads they paid for"). Balance fields are nil in
# that view, which the app treats as "don't show a balance".
class GiftCardSerializer
  MAX_INLINE_LOADS = 20

  # @param attachment_url [#call] resolves an ActiveStorage attachment to a URL (nil-safe)
  # @param viewer [User] the user the JSON is for (decides recipient vs sender view)
  def initialize(card, attachment_url:, viewer:)
    @card = card
    @attachment_url = attachment_url
    @viewer = viewer
  end

  def self.call(card, attachment_url:, viewer:)
    new(card, attachment_url: attachment_url, viewer: viewer).as_json
  end

  def as_json
    recipient_view? ? recipient_json : sender_json
  end

  def recipient_view?
    viewer.present? && card.recipient_id == viewer.id
  end

  def serialize_load(load)
    GiftCardLoadSerializer.call(load, attachment_url: attachment_url)
  end

  private

  def recipient_json
    balances = card.balances
    loads = card.loads.reject(&:status_canceled?)
    latest = loads.max_by { |l| [ l.created_at, l.id ] }
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
      loads: loads.sort_by { |l| [ -l.created_at.to_f, -l.id ] }.first(MAX_INLINE_LOADS).map { |l| serialize_load(l) },
      viewer_role: "recipient"
    }
  end

  # Same keys (the app's types expect them), scoped to the viewer's own loads.
  def sender_json
    own = card.loads.reject(&:status_canceled?).select { |l| viewer && l.sender_id == viewer.id }
    latest = own.max_by { |l| [ l.created_at, l.id ] }
    own_total = own.sum(&:amount_cents)
    own_balances = card.balances(only_sender: viewer)
    merchant_logo_url = attachment_url.call(card.merchant&.logo)

    {
      id: card.id,
      amount_cents: own_total,
      remaining_balance_cents: own_balances[:remaining_balance],
      spendable_cents: own_balances[:spendable_cents],
      held_cents: own_balances[:held_cents],
      disputed_cents: own_balances[:disputed_cents],
      total_loaded_cents: own_total,
      loads_count: own.size,
      last_loaded_at: latest&.created_at&.iso8601,
      currency: card.currency,
      status: public_status,
      frozen_reason: nil,
      created_at: card.created_at&.iso8601,
      updated_at: card.updated_at&.iso8601,
      sender_id: latest&.sender_id,
      recipient_id: card.recipient_id,
      merchant_id: card.merchant_id,
      merchant: card.merchant ? { id: card.merchant.id, store_name: card.merchant.store_name, logo_url: merchant_logo_url } : nil,
      store_name: card.merchant&.store_name,
      merchant_name: card.merchant&.store_name,
      merchant_store_name: card.merchant&.store_name,
      merchant_logo_url: merchant_logo_url,
      note: latest&.note,
      sender: serialize_sender(latest&.sender),
      held_until: own_balances[:held_until]&.iso8601,
      loads: own.sort_by { |l| [ -l.created_at.to_f, -l.id ] }.first(MAX_INLINE_LOADS).map { |l| serialize_load(l) },
      viewer_role: "sender"
    }
  end

  attr_reader :card, :attachment_url, :viewer

  def public_status
    card.public_status
  end

  def serialize_sender(sender)
    return nil unless sender

    {
      id: sender.id,
      name: sender.first_name,
      last_name: sender.last_name,
      full_name: sender.full_name.presence,
      avatar_url: attachment_url.call(sender.avatar)
    }
  end
end
