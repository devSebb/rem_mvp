# Shared by the per-load and card-level (compat) share/resend endpoints
# (RELOADABLE_CARD_PLAN.md §5.9). A claim link is a doorway, not a key —
# claiming still requires the recipient's OTP at signup.
module LoadSharing
  extend ActiveSupport::Concern

  private

  def render_share_link(load)
    unless load.gift_card.active?
      return render_error(
        code: "gift_card.inactive",
        message: "Tarjeta inactiva o no disponible",
        status: :unprocessable_entity
      )
    end

    claim_url = ::GiftCards::ClaimLink.url_for(load)

    render_success(
      data: {
        load_id: load.id,
        gift_card_id: load.gift_card_id,
        claim_url: claim_url,
        message: share_message(load, claim_url)
      }
    )
  end

  def render_resend(load)
    unless load.gift_card.active?
      return render_error(
        code: "gift_card.inactive",
        message: "Tarjeta inactiva o no disponible",
        status: :unprocessable_entity
      )
    end

    ::GiftCards::ResendDelivery.call(load: load)

    render_success(data: { resent: true, load_id: load.id, gift_card_id: load.gift_card_id })
  rescue ::GiftCards::ResendDelivery::Throttled => e
    render_error(
      code: "gift_card.resend_throttled",
      message: "Ya reenviamos la notificación hace poco. Intenta de nuevo más tarde.",
      status: :too_many_requests,
      details: { retry_in_seconds: e.retry_in_seconds }
    )
  end

  # §4.4 "WhatsApp share message (server-generated)". Copy lives server-side
  # so wording can be tuned without an app release.
  def share_message(load, claim_url)
    card = load.gift_card
    recipient_name = card.recipient&.first_name.presence || card.recipient&.name.presence
    greeting = recipient_name ? "¡Hola #{recipient_name}!" : "¡Hola!"
    merchant_name = card.merchant&.store_name || "Papayal"
    amount = Messaging::Money.format(load.amount_cents, currency: load.currency)

    if card.first_load&.id == load.id
      "#{greeting} Te envié una tarjeta de regalo digital de #{merchant_name} por #{amount} con Papayal. Ábrela aquí: #{claim_url}"
    else
      "#{greeting} Añadí #{amount} a tu tarjeta de #{merchant_name} en Papayal. Míralo aquí: #{claim_url}"
    end
  end
end
