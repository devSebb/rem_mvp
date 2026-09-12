class PurchaseConfirmationMailer < ApplicationMailer
  layout "branded_mailer"

  MONTHS_ES = %w[enero febrero marzo abril mayo junio julio agosto septiembre octubre noviembre diciembre].freeze
  RECEIPT_TZ = "America/Guayaquil".freeze # Ecuador (UTC-5)

  # Buyer-facing receipt for ONE load (§5.9 "receipt mailer per load").
  # Distinct from GiftCardMailer#deliver_gift_card, which goes to the
  # RECIPIENT. Sent by Loads::Fulfill once the purchase ledger row exists.
  #
  # Takes only the load id so deliver_later serializes cleanly; the fee
  # breakdown is read back off the purchase transaction's metadata.
  def receipt(gift_card_load_id)
    @load = GiftCardLoad.find(gift_card_load_id)
    @gift_card = @load.gift_card
    @sender = @load.sender
    @support_email = ENV['DEFAULT_FROM_EMAIL'].presence || 'hola@papayal.app'

    # No real buyer email to send to (e.g. legacy/placeholder rows) — skip.
    return if @sender.nil? || @sender.email.blank? || @sender.placeholder_email?

    @merchant = @gift_card.merchant
    @currency = @load.currency
    @purchased_at_str = format_date_es(@load.created_at)
    @first_load = @gift_card.loads.in_scope.fifo.first&.id == @load.id
    @self_load = @load.sender_id == @gift_card.recipient_id

    txn = @load.transactions.where(txn_type: :purchase).order(:created_at).last
    meta = txn&.metadata || {}
    @subtotal_cents = (meta['subtotal_cents'] || @load.amount_cents).to_i
    @fee_cents = (meta['fee_cents'] || @load.fee_cents).to_i
    @total_cents = (meta['total_paid_cents'] || (@subtotal_cents + @fee_cents)).to_i
    @reference = @load.payment_intent_id.presence || txn&.processor_ref

    @recipient_label = recipient_label(@gift_card.recipient)
    merchant_name = @merchant&.store_name || "Papayal"

    subject =
      if @self_load
        "Tu recarga de #{money(@subtotal_cents)} en #{merchant_name}"
      elsif @first_load
        "Tu tarjeta de regalo digital de #{merchant_name} para #{@recipient_label}"
      else
        "Tu recarga de #{money(@subtotal_cents)} para #{@recipient_label} en #{merchant_name}"
      end

    mail(to: @sender.email, subject: subject)
  end

  private

  def money(cents)
    Messaging::Money.format(cents, currency: @currency)
  end
  helper_method :money

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
