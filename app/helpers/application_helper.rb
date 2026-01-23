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

    "Tu billetera de regalos"
  end

  def navbar_home_path
    # If not logged in, redirect to www.papayal.app
    return "https://www.papayal.app" unless user_signed_in?
    
    # If logged in, use normal behavior
    return merchant_root_path if current_user&.merchant? || merchant_nav_context?

    home_path
  end

  def merchant_nav_context?
    controller_path.start_with?("merchant/")
  end

  def avatar_url_for(record, attachment_name: :avatar, resize_to_limit: [96, 96])
    attachment = record.respond_to?(attachment_name) ? record.public_send(attachment_name) : nil
    fallback = asset_path("default-avatar.svg")

    return fallback unless attachment&.attached?

    # For small avatars (48px or less), use original to avoid variant processing issues
    # For larger sizes, try to use variant for optimization
    use_variant = resize_to_limit.any? { |dim| dim > 48 } && attachment.variable?

    if use_variant
      begin
        variant = attachment.variant(resize_to_limit: resize_to_limit)
        # Generate URL - Rails will process the variant on-demand
        return url_for(variant)
      rescue => e
        Rails.logger.warn("Avatar variant failed: #{e.class} - #{e.message}, falling back to original")
        # Fall back to original image if variant fails
      end
    end

    # Use original image (for small sizes or if variant failed)
    begin
      url_for(attachment)
    rescue => e
      Rails.logger.warn("Avatar URL fallback triggered: #{e.class} - #{e.message}")
      fallback
    end
  end

  def avatar_image_for(record, attachment_name: :avatar, size: 48, classes: "")
    url = avatar_url_for(record, attachment_name:, resize_to_limit: [size, size])
    image_tag(
      url,
      alt: record.respond_to?(:name) ? record.name : "Avatar",
      class: "rounded-full border border-black/10 bg-white object-cover #{classes}".squeeze(" "),
      style: "width: #{size}px; height: #{size}px; min-width: #{size}px; min-height: #{size}px;"
    )
  end

  def merchant_logo_url(merchant, resize_to_limit: [96, 96])
    fallback = asset_path("merchant-default.svg")

    return fallback unless merchant.logo.attached?

    use_variant = resize_to_limit.any? { |dim| dim > 48 } && merchant.logo.variable?

    if use_variant
      begin
        variant = merchant.logo.variant(resize_to_limit: resize_to_limit)
        return url_for(variant)
      rescue => e
        Rails.logger.warn("Merchant logo variant failed: #{e.class} - #{e.message}")
      end
    end

    begin
      url_for(merchant.logo)
    rescue => e
      Rails.logger.warn("Merchant logo URL fallback: #{e.class} - #{e.message}")
      fallback
    end
  end

  def merchant_logo_image(merchant, size: 64, classes: "", rounded: "2xl")
    url = merchant_logo_url(merchant, resize_to_limit: [size, size])
    content_tag(:div,
      image_tag(
        url,
        alt: merchant.store_name,
        class: "max-w-full max-h-full w-auto h-auto object-contain"
      ),
      class: "rounded-#{rounded} border border-black/10 bg-white flex items-center justify-center overflow-hidden #{classes}".squeeze(" "),
      style: "width: #{size}px; height: #{size}px;"
    )
  end
end
