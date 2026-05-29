module Messaging
  class Notifier
    include Rails.application.routes.url_helpers

    def initialize(gift_card)
      @gift_card = gift_card
      @recipient = gift_card.recipient
      @sender = gift_card.sender
    end

    def send_all_notifications
      results = {}

      # Phone channel: respects user preference; WhatsApp first with SMS fallback by default.
      if @recipient&.phone.present?
        phone_result = send_phone_channel
        results[phone_result[:via]] = phone_result if phone_result[:via]
      end

      # Send Email only if recipient has a real address.
      # Pending recipients with placeholder emails (claim+<hash>@papayal.app)
      # haven't signed up yet — skip email, the SMS/WhatsApp path delivers.
      if @recipient&.email.present? && !@recipient.placeholder_email?
        results[:email] = send_email
      end

      # Send push notification if recipient has active push tokens
      results[:push] = send_push

      # Update delivery flags
      update_delivery_flags(results)

      results
    end

    # Sends via the user's preferred phone channel. If preference is :whatsapp
    # (default) and WhatsApp delivery fails, automatically falls back to SMS.
    # Returns a hash with :via (:whatsapp or :sms) plus the underlying result.
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
      unless from_number.present?
        return twilio_disabled_response(:whatsapp, 'TWILIO_WHATSAPP_NUMBER missing')
      end

      begin
        message = client.messages.create(
          from: "whatsapp:#{from_number}",
          to: "whatsapp:#{@recipient.phone}",
          body: whatsapp_message
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
      unless from_number.present?
        return twilio_disabled_response(:sms, 'TWILIO_PHONE_NUMBER missing')
      end

      begin
        message = client.messages.create(
          from: from_number,
          to: @recipient.phone,
          body: sms_message
        )

        { success: true, sid: message.sid }
      rescue Twilio::REST::RestError => e
        Rails.logger.error "SMS delivery failed: #{e.message}"
        { success: false, error: e.message }
      end
    end

    def send_push
      return { success: false, error: "No recipient" } unless @recipient

      amount_label = "#{@gift_card.currency} #{"%.2f" % (@gift_card.amount / 100.0)}"
      merchant_name = @gift_card.merchant&.store_name || "Papayal"

      Messaging::PushSender.new.send_to_user(
        @recipient,
        title: "#{merchant_name} — #{amount_label}",
        body: "#{@sender&.name || "Alguien"} te envi\u00F3 una tarjeta de regalo Papayal",
        data: { type: "gift_card_received", gift_card_id: @gift_card.id.to_s }
      )
    rescue => e
      Rails.logger.error "[Push] Failed: #{e.class} - #{e.message}"
      { success: false, error: e.message }
    end

    def send_email
      return { success: false, error: 'No email address' } unless @recipient&.email.present?

      begin
        # Try deliver_later first, fallback to deliver_now if Sidekiq not available
        mail = GiftCardMailer.deliver_gift_card(@gift_card)

        begin
          mail.deliver_later
          Rails.logger.info "📧 Email queued for delivery to #{@recipient.email}"
        rescue NoMethodError, Redis::CannotConnectError => e
          # Sidekiq not available or Redis not running - use sync
          Rails.logger.warn "⚠️ Sidekiq not available for email (#{e.class}), sending immediately"
          mail.deliver_now
          Rails.logger.info "📧 Email sent immediately to #{@recipient.email}"
        end

        { success: true }
      rescue => e
        Rails.logger.error "❌ Email delivery failed to #{@recipient.email}: #{e.class} - #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        { success: false, error: e.message }
      end
    end

    private

    def whatsapp_message
      raw_code = @gift_card.raw_code || @gift_card.generate_code!
      <<~MESSAGE
        🎁 ¡Recibiste una tarjeta de regalo Papayal!

        💰 Monto: #{@gift_card.currency} #{format("%.2f", @gift_card.amount / 100.0)}
        👤 De: #{@sender.name}

        🎫 Tu código: #{raw_code}

        📱 Muestra este código en cualquier comercio participante
        ⏰ Sin fecha de vencimiento — úsalo cuando quieras

        ¡Gracias por usar Papayal! 🎉
      MESSAGE
    end

    def sms_message
      raw_code = @gift_card.raw_code || @gift_card.generate_code!
      <<~MESSAGE
        🎁 Tarjeta de regalo Papayal recibida.
        Monto: #{@gift_card.currency} #{format("%.2f", @gift_card.amount / 100.0)}
        De: #{@sender.name}
        Código: #{raw_code}
        Muéstralo en caja. Sin vencimiento.
      MESSAGE
    end

    def update_delivery_flags(results)
      updates = {}
      updates[:sent_via_whatsapp] = true if results[:whatsapp]&.dig(:success)
      updates[:sent_via_sms] = true if results[:sms]&.dig(:success)
      updates[:sent_via_email] = true if results[:email]&.dig(:success)
      updates[:sent_via_push] = true if results[:push]&.dig(:success)

      @gift_card.update!(updates) if updates.any?
    end

    def twilio_disabled_response(channel, reason = 'Twilio not configured')
      Rails.logger.warn "[Twilio] #{reason}; #{channel} not sent"
      { success: false, error: reason }
    end
  end
end
