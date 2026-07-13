class PurchaseConfirmationMailer < ApplicationMailer
  layout "branded_mailer"

  MONTHS_ES = %w[enero febrero marzo abril mayo junio julio agosto septiembre octubre noviembre diciembre].freeze
  RECEIPT_TZ = "America/Guayaquil".freeze # Ecuador (UTC-5)

  # Buyer-facing receipt for a completed gift card purchase. Distinct from
  # GiftCardMailer#deliver_gift_card, which goes to the RECIPIENT. Sent from
  # the Stripe webhook once the purchase transaction is recorded.
  #
  # Takes only the gift card id so deliver_later serializes cleanly; the fee
  # breakdown is read back off the purchase transaction's metadata (written
  # in StripeWebhooks#fulfill_payment_intent!).
  def receipt(gift_card_id)
    @gift_card = GiftCard.find(gift_card_id)
    @sender = @gift_card.sender
    @support_email = ENV['DEFAULT_FROM_EMAIL'].presence || 'hola@papayal.app'

    # No real buyer email to send to (e.g. legacy/placeholder rows) — skip.
    return if @sender.nil? || @sender.email.blank? || @sender.placeholder_email?

    @merchant = @gift_card.merchant
    @currency = @gift_card.currency
    # Spanish, Ecuador-local date string — built by hand so it never leaks
    # the app's :en I18n default (e.g. "July 13, 2026") or a UTC timestamp.
    @purchased_at_str = format_date_es(@gift_card.created_at)

    txn = @gift_card.transactions.where(txn_type: :purchase).order(:created_at).last
    meta = txn&.metadata || {}
    @subtotal_cents = (meta['subtotal_cents'] || @gift_card.amount).to_i
    @fee_cents = (meta['fee_cents'] || 0).to_i
    @total_cents = (meta['total_paid_cents'] || (@subtotal_cents + @fee_cents)).to_i
    @reference = @gift_card.payment_intent_id.presence || txn&.processor_ref

    @recipient_label = recipient_label(@gift_card.recipient)

    mail(
      to: @sender.email,
      subject: "Tu recibo de Papayal — #{money(@total_cents)}"
    )
  end

  private

  def money(cents)
    "#{@currency} #{format('%.2f', cents.to_i / 100.0)}"
  end

  # e.g. "12 de julio de 2026, 22:12" in Ecuador local time.
  def format_date_es(time)
    return nil if time.blank?

    local = time.in_time_zone(RECEIPT_TZ)
    "#{local.day} de #{MONTHS_ES[local.month - 1]} de #{local.year}, #{local.strftime('%H:%M')}"
  end

  # A friendly "sent to" label that never leaks a full contact detail:
  # the recipient's name if we have one, otherwise a masked email/phone.
  def recipient_label(recipient)
    return "un destinatario" if recipient.nil?

    name = recipient.full_name.presence
    return name if name

    if recipient.email.present? && !recipient.placeholder_email?
      local, _, domain = recipient.email.partition("@")
      return "#{local[0]}•••@#{domain}"
    end

    if recipient.phone.present?
      digits = recipient.phone.to_s
      return digits.length <= 8 ? "•••#{digits.last(2)}" : "#{digits.first(4)}•••#{digits.last(4)}"
    end

    "un destinatario"
  end
end
