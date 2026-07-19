# Presentation for the admin card ledger. txn_type alone is ambiguous — a
# Stripe refund to the buyer and a merchant redemption reversal are both
# txn_type "refund" — so entries are classified with the metadata the
# services write, and every metadata key is rendered (pretty-labeled where
# known) so the timeline is the full audit trail, not a summary of it.
module Admin::GiftCardsHelper
  TXN_TONES = {
    "emerald" => { dot: "bg-emerald-500", text: "text-emerald-700" },
    "blue" => { dot: "bg-blue-500", text: "text-blue-700" },
    "rose" => { dot: "bg-rose-500", text: "text-rose-700" },
    "amber" => { dot: "bg-amber-500", text: "text-amber-700" },
    "slate" => { dot: "bg-slate-400", text: "text-slate-600" }
  }.freeze

  METADATA_LABELS = {
    "stripe_refund_id" => "Refund Stripe",
    "stripe_charge_id" => "Charge Stripe",
    "stripe_dispute_id" => "Disputa Stripe",
    "reason" => "Motivo",
    "refund_status_at_apply" => "Estado del refund",
    "previous_card_status" => "Estado anterior de la tarjeta",
    "previous_remaining_balance" => "Saldo anterior",
    "refunded_at" => "Reembolsado",
    "refund_failed_at" => "Refund falló",
    "refund_failure_reason" => "Motivo del fallo",
    "written_off_at" => "Anulado",
    "redeemed_at" => "Canjeado",
    "transferred_at" => "Transferido",
    "source" => "Origen",
    "action" => "Acción",
    "actor_id" => "Actor (user id)",
    "actor_type" => "Tipo de actor",
    "merchant_id" => "Comercio (id)",
    "from_user_id" => "De (user id)",
    "to_user_id" => "Para (user id)",
    "subtotal_cents" => "Subtotal",
    "fee_cents" => "Tarifa",
    "stripe_fee_cents" => "Costo Stripe",
    "stripe_net_cents" => "Neto Stripe"
  }.freeze

  def admin_txn_presentation(txn)
    meta = txn.metadata || {}
    case
    when txn.refund? && meta["stripe_refund_id"].present?
      { label: "Reembolso Stripe al comprador", tone: "rose",
        note: "Sale dinero de la plataforma; el saldo de la tarjeta baja." }
    when txn.refund?
      { label: "Reversa de canje", tone: "amber",
        note: "Se revierte un canje; el saldo vuelve a la tarjeta." }
    when txn.adjustment? && meta["source"] == "dispute_lost"
      { label: "Disputa perdida — saldo anulado", tone: "rose",
        note: "Contracargo perdido: la tarjeta se canceló y el saldo se dio de baja." }
    when txn.adjustment? && meta["action"] == "transfer"
      { label: "Transferencia de titular", tone: "slate",
        note: "La tarjeta cambió de destinatario; no se movió dinero." }
    when txn.adjustment?
      { label: "Ajuste", tone: "slate" }
    when txn.purchase?
      { label: "Compra", tone: "emerald" }
    when txn.redemption?
      { label: "Canje", tone: "blue" }
    when txn.issuance?
      { label: "Emisión", tone: "emerald" }
    else
      { label: txn.txn_type.to_s.humanize, tone: "slate" }
    end
  end

  def admin_txn_tone_classes(tone)
    TXN_TONES.fetch(tone, TXN_TONES["slate"])
  end

  def admin_txn_metadata_rows(txn)
    (txn.metadata || {}).map do |key, value|
      [METADATA_LABELS.fetch(key.to_s, key.to_s.humanize), admin_txn_metadata_value(key.to_s, value)]
    end
  end

  private

  def admin_txn_metadata_value(key, value)
    return "—" if value.nil? || value.to_s.strip.empty?

    if key.end_with?("_cents") || key == "previous_remaining_balance"
      number_to_currency(value.to_i / 100.0, unit: "$")
    elsif (time = parse_metadata_time(value))
      time.in_time_zone.strftime("%d/%m/%Y %H:%M")
    else
      value.to_s
    end
  end

  def parse_metadata_time(value)
    return nil unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}T/)

    Time.iso8601(value)
  rescue ArgumentError
    nil
  end
end
