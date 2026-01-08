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

  def navbar_subtitle
    return tag.span("comercio", class: "italic") if merchant_nav_context?

    "Tu billetera de regalos cálida"
  end

  def navbar_home_path
    return merchant_root_path if current_user&.merchant? || merchant_nav_context?

    root_path
  end

  def merchant_nav_context?
    controller_path.start_with?("merchant/")
  end

  def avatar_url_for(record, attachment_name: :avatar, resize_to_limit: [96, 96])
    attachment = record.respond_to?(attachment_name) ? record.public_send(attachment_name) : nil
    fallback = asset_path("default-avatar.svg")

    return fallback unless attachment&.attached?

    if attachment.variable?
      begin
        return url_for(attachment.variant(resize_to_limit: resize_to_limit))
      rescue => e
        Rails.logger.warn("Avatar variant failed: #{e.class} - #{e.message}")
      end
    end

    url_for(attachment)
  rescue => e
    Rails.logger.warn("Avatar URL fallback triggered: #{e.class} - #{e.message}")
    fallback
  end

  def avatar_image_for(record, attachment_name: :avatar, size: 48, classes: "")
    url = avatar_url_for(record, attachment_name:, resize_to_limit: [size, size])
    image_tag(
      url,
      alt: record.respond_to?(:name) ? record.name : "Avatar",
      class: "rounded-full border border-black/10 bg-white object-cover h-#{size / 4 * 1} w-#{size / 4 * 1} #{classes}".squeeze(" "),
      size: "#{size}x#{size}"
    )
  end
end
