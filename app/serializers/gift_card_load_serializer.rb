# §8.1 `loads[]` entry and the §8.2 "Enviadas" row. One shape, two views:
#   :card — a load as seen on its card (recipient or any sender)
#   :sent — a load the current user paid, with card summary, masked
#           recipient and claim/refund state
class GiftCardLoadSerializer
  def initialize(load, attachment_url:)
    @load = load
    @card = load.gift_card
    @attachment_url = attachment_url
  end

  def self.call(load, attachment_url:, view: :card)
    new(load, attachment_url: attachment_url).as_json(view: view)
  end

  def as_json(view: :card)
    base = {
      id: load.id,
      gift_card_id: load.gift_card_id,
      amount_cents: load.amount_cents,
      remaining_cents: load.remaining_cents,
      refunded_cents: load.refunded_cents,
      written_off_cents: load.written_off_cents,
      currency: load.currency,
      source: load.source,
      sender_id: load.sender_id,
      sender: serialize_sender(load.sender),
      note: load.note,
      status: load.derived_status.to_s,
      held_until: load.held? ? load.held_until.iso8601 : nil,
      disputed_at: load.dispute_open? ? load.disputed_at.iso8601 : nil,
      created_at: load.created_at&.iso8601,
      is_self: load.self_load?
    }
    return base unless view == :sent

    base.merge(
      refundable_cents: load.refundable_cents,
      claim_status: claim_status,
      recipient: serialize_recipient(card&.recipient),
      gift_card: card_summary
    )
  end

  private

  attr_reader :load, :card, :attachment_url

  def claim_status
    card&.recipient&.claimed_at.present? ? "claimed" : "pending_claim"
  end

  def card_summary
    return nil unless card

    balances = card.balances
    {
      id: card.id,
      status: card.public_status,
      merchant_id: card.merchant_id,
      merchant: card.merchant ? { id: card.merchant.id, store_name: card.merchant.store_name, logo_url: attachment_url.call(card.merchant.logo) } : nil,
      spendable_cents: balances[:spendable_cents],
      remaining_balance_cents: balances[:remaining_balance],
      total_loaded_cents: card.total_loaded_cents.to_i,
      loads_count: card.loads_count.to_i
    }
  end

  # The buyer sees who they sent to, never the full contact (§8.2).
  def serialize_recipient(recipient)
    return nil unless recipient

    {
      id: recipient.id,
      name: recipient.first_name.presence || recipient.name.presence,
      full_name: recipient.full_name.presence,
      masked_phone: mask_phone(recipient.phone),
      masked_email: mask_email(recipient.placeholder_email? ? nil : recipient.email),
      registered: recipient.claimed_at.present?
    }
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

  def mask_phone(phone)
    return nil if phone.blank?

    digits = phone.to_s
    return "•••#{digits.last(2)}" if digits.length <= 8

    "#{digits.first(4)}•••#{digits.last(4)}"
  end

  def mask_email(email)
    return nil if email.blank?

    local, _, domain = email.partition("@")
    "#{local[0]}•••@#{domain}"
  end
end
