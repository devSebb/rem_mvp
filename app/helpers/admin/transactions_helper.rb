module Admin::TransactionsHelper
  TXN_TYPE_LABELS = {
    "purchase" => "Compra",
    "redemption" => "Canje",
    "refund" => "Reembolso",
    "adjustment" => "Ajuste",
    "issuance" => "Emisión"
  }.freeze

  TXN_STATUS_LABELS = {
    "pending" => "Pendiente",
    "succeeded" => "Exitosa",
    "failed" => "Fallida"
  }.freeze

  def admin_txn_type_label(txn_type)
    TXN_TYPE_LABELS.fetch(txn_type.to_s, txn_type.to_s.humanize)
  end

  def admin_txn_status_label(status)
    TXN_STATUS_LABELS.fetch(status.to_s, status.to_s.humanize)
  end

  def admin_txn_status_badge(status)
    preset = { "succeeded" => "active", "failed" => "expired", "pending" => "pending" }.fetch(status.to_s, "pending")
    tag.span(admin_txn_status_label(status), class: status_badge_classes(preset))
  end

  # Current filters (parsed, not raw params — garbage never propagates into
  # links) merged with overrides, for pills and pagination.
  def admin_transactions_filter_path(overrides = {})
    admin_transactions_path(
      {
        type: (@type unless @type == "all"),
        status: (@status unless @status == "all"),
        merchant_id: @merchant_id,
        from: @from&.iso8601,
        to: @to&.iso8601,
        q: @query.presence
      }.merge(overrides).compact_blank
    )
  end
end
