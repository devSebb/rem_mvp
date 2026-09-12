module Messaging
  # Recipient-facing delivery for ONE load (RELOADABLE_CARD_PLAN.md §5.9,
  # copy §4.4). Three templates:
  #   first load on the card → "recibiste una tarjeta de regalo digital…"
  #   reload                 → "{Sender} añadió $X a tu tarjeta…" + spendable
  #   self-load              → push only ("Recarga confirmada")
  # Delivery flags (sent_via_*) live on the load so a Sidekiq retry after a
  # partial failure never double-sends and a reload always gets its own
  # notification.
  class Notifier
    include Rails.application.routes.url_helpers

    def initialize(load)
      @load = load
      @gift_card = load.gift_card
      @recipient = @gift_card&.recipient
      @sender = load.sender
    end

    def send_all_notifications
      results = {}

      if self_load?
        results[:push] = send_push unless @load.sent_via_push?
        update_delivery_flags(results)
        return results
      end

      # Phone channel: respects user preference; WhatsApp first with SMS fallback by default.
      if @recipient&.phone.present? && !@load.sent_via_whatsapp? && !@load.sent_via_sms?
        phone_result = send_phone_channel
        results[phone_result[:via]] = phone_result if phone_result[:via]
      end

      # Email only for a real address: pending recipients carry a
      # placeholder (claim+<hash>@papayal.app) until they sign up.
      if @recipient&.email.present? && !@recipient.placeholder_email? && !@load.sent_via_email?
        results[:email] = send_email
      end

      results[:push] = send_push unless @load.sent_via_push?

      update_delivery_flags(results)
      results
    end

    # Sender-triggered re-delivery: same channels as send_all_notifications
    # but ignoring the sent_via_* first-delivery guards. Flags are still
    # updated on success. Throttled upstream in GiftCards::ResendDelivery.
    def resend_delivery
      results = {}

      unless self_load?
        if @recipient&.phone.present?
          phone_result = send_phone_channel
          results[phone_result[:via]] = phone_result if phone_result[:via]
        end

        if @recipient&.email.present? && !@recipient.placeholder_email?
          results[:email] = send_email
        end
      end

      results[:push] = send_push

      update_delivery_flags(results)
      results
    end

    # Sends via the user's preferred phone channel. If preference is :whatsapp
    # (default) and WhatsApp delivery fails, automatically falls back to SMS.
    def send_phone_channel
      if @recipient.preferred_channel == "sms"
        return send_sms.merge(via: :sms)
      end

      whatsapp_result = send_whatsapp
      return whatsapp_result.merge(via: :whatsapp) if whatsapp_result[:success]

      Rails.logger.info "[Notifier] WhatsApp delivery failed for user #{@recipient.id} (#{whatsapp_result[:error]}); falling back to SMS"
      sms_result = send_sms
      sms_result.merge(via: :sms, whatsapp_attempted: true, whatsapp_error: whatsapp_result[:error])
    end

    def send_whatsapp
      return { success: false, error: 'No phone number' } unless @recipient&.phone.present?
      return twilio_disabled_response(:whatsapp) unless Messaging::TwilioConfig.enabled?

      client = Messaging::TwilioConfig.client
      return twilio_disabled_response(:whatsapp, 'Twilio client unavailable') unless client

      from_number = Messaging::TwilioConfig.whatsapp_number
      return twilio_disabled_response(:whatsapp, 'TWILIO_WHATSAPP_NUMBER missing') unless from_number.present?

      begin
        message = client.messages.create(
          from: "whatsapp:#{from_number}",
          to: "whatsapp:#{@recipient.phone}",
          body: phone_message
        )
        { success: true, sid: message.sid }
      rescue Twilio::REST::RestError => e
        Rails.logger.error "WhatsApp delivery failed: #{e.message}"
        { success: false, error: e.message }
      end
    end

    def send_sms
      return { success: false, error: 'No phone number' } unless @recipient&.phone.present?
      return twilio_disabled_response(:sms) unless Messaging::TwilioConfig.enabled?

      client = Messaging::TwilioConfig.client
      return twilio_disabled_response(:sms, 'Twilio client unavailable') unless client

      from_number = Messaging::TwilioConfig.from_number
      return twilio_disabled_response(:sms, 'TWILIO_PHONE_NUMBER missing') unless from_number.present?

      begin
        message = client.messages.create(from: from_number, to: @recipient.phone, body: phone_message)
        { success: true, sid: message.sid }
      rescue Twilio::REST::RestError => e
        Rails.logger.error "SMS delivery failed: #{e.message}"
        { success: false, error: e.message }
      end
    end

    def send_push
      return { success: false, error: "No recipient" } unless @recipient

      Messaging::PushSender.new.send_to_user(@recipient, **push_payload)
    rescue => e
      Rails.logger.error "[Push] Failed: #{e.class} - #{e.message}"
      { success: false, error: e.message }
    end

    def send_email
      return { success: false, error: 'No email address' } unless @recipient&.email.present?

      begin
        mail = GiftCardMailer.deliver_gift_card(@load)
        begin
          mail.deliver_later
          Rails.logger.info "📧 Email queued for delivery to #{@recipient.email}"
        rescue NoMethodError, Redis::CannotConnectError => e
          Rails.logger.warn "⚠️ Sidekiq not available for email (#{e.class}), sending immediately"
          mail.deliver_now
        end
        { success: true }
      rescue => e
        Rails.logger.error "❌ Email delivery failed to #{@recipient.email}: #{e.class} - #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        { success: false, error: e.message }
      end
    end

    # ── Template selection (§5.9) ───────────────────────────────────────
    def first_load?
      @first_load = @gift_card.loads.in_scope.fifo.first&.id == @load.id if @first_load.nil?
      @first_load
    end

    def self_load?
      @load.sender_id.present? && @recipient.present? && @load.sender_id == @recipient.id
    end

    # §4.4 "Notifications (server templates)"
    def push_payload
      merchant = merchant_label
      data = { gift_card_id: @gift_card.id.to_s, load_id: @load.id.to_s }
      if self_load?
        { title: "Recarga confirmada", body: "#{amount_label} en tu tarjeta de #{merchant}.",
          data: data.merge(type: "gift_card_topped_up") }
      elsif first_load?
        { title: "🎁 Tarjeta de regalo de #{merchant}", body: "#{sender_label} te envió #{amount_label} para usar en #{merchant}.",
          data: data.merge(type: "gift_card_received") }
      else
        { title: "Recarga en tu tarjeta de #{merchant}", body: "#{sender_label} añadió #{amount_label}. Saldo disponible: #{spendable_label}.",
          data: data.merge(type: "gift_card_topped_up") }
      end
    end

    # WhatsApp and SMS share one body. Delivery messages carry the claim
    # link, never a redemption code: merchants only accept the short-lived
    # in-app token, and the claim itself is OTP-verified at signup.
    def phone_message
      greeting = recipient_first_name ? "¡Hola #{recipient_first_name}!" : "¡Hola!"
      if first_load?
        "#{greeting} #{sender_label} te envió una tarjeta de regalo digital de #{merchant_label} por #{amount_label} en Papayal. " \
          "Descarga la app y reclámala con este número: #{claim_url}"
      else
        msg = "#{greeting} #{sender_label} añadió #{amount_label} a tu tarjeta de #{merchant_label} en Papayal. Saldo disponible: #{spendable_label}."
        # A recipient who never claimed their account still needs the doorway.
        msg += " Reclámala aquí: #{claim_url}" if @recipient&.pending?
        msg
      end
    end

    private

    def claim_url
      @claim_url ||= GiftCards::ClaimLink.url_for(@load)
    end

    def amount_label
      Messaging::Money.format(@load.amount_cents)
    end

    def spendable_label
      Messaging::Money.format(@gift_card.reload.spendable_cents)
    end

    def merchant_label
      @gift_card.merchant&.store_name || "Papayal"
    end

    def sender_label
      @sender&.first_name.presence || @sender&.name.presence || "Alguien"
    end

    def recipient_first_name
      @recipient&.first_name.presence || @recipient&.name.presence
    end

    def update_delivery_flags(results)
      updates = {}
      updates[:sent_via_whatsapp] = true if results[:whatsapp]&.dig(:success)
      updates[:sent_via_sms] = true if results[:sms]&.dig(:success)
      updates[:sent_via_email] = true if results[:email]&.dig(:success)
      updates[:sent_via_push] = true if results[:push]&.dig(:success)

      @load.update_columns(updates.merge(updated_at: Time.current)) if updates.any?
    end

    def twilio_disabled_response(channel, reason = 'Twilio not configured')
      Rails.logger.warn "[Twilio] #{reason}; #{channel} not sent"
      { success: false, error: reason }
    end
  end
end
