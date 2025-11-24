module ApplicationHelper
  STATUS_PRESETS = {
    "active" => { label: "Activa", classes: "bg-emerald-50 text-emerald-700 border border-emerald-100" },
    "redeemed" => { label: "Canjeada", classes: "bg-blue-50 text-blue-700 border border-blue-100" },
    "expired" => { label: "Vencida", classes: "bg-rose-50 text-rose-700 border border-rose-100" },
    "canceled" => { label: "Cancelada", classes: "bg-gray-100 text-gray-600 border border-gray-200" },
    "pending" => { label: "Pendiente", classes: "bg-amber-50 text-amber-700 border border-amber-100" }
  }.freeze

  def status_badge_classes(status)
    preset = STATUS_PRESETS[status.to_s] || { classes: "bg-[#0D2F32]/5 text-[#0D2F32] border border-[#0D2F32]/10" }
    "inline-flex items-center gap-1 px-3 py-1 rounded-full text-xs font-medium #{preset[:classes]}"
  end

  def status_badge_label(status)
    STATUS_PRESETS[status.to_s]&.fetch(:label, nil) || status.to_s.humanize
  end
end
