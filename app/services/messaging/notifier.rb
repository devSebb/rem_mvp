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
      
      # Send WhatsApp if recipient has phone
      if @recipient&.phone.present?
        results[:whatsapp] = send_whatsapp
      end

      # Send SMS if recipient has phone
      if @recipient&.phone.present?
        results[:sms] = send_sms
      end

      # Send Email if recipient has email
      if @recipient&.email.present?
        results[:email] = send_email
      end

      # Update delivery flags
      update_delivery_flags(results)

      results
    end

    def send_whatsapp
      return { success: false, error: 'No phone number' } unless @recipient&.phone.present?

      begin
        client = Twilio::REST::Client.new(
          Rails.application.config.twilio[:account_sid],
          Rails.application.config.twilio[:auth_token]
        )

        message = client.messages.create(
          from: "whatsapp:#{ENV['TWILIO_WHATSAPP_NUMBER']}",
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

      begin
        client = Twilio::REST::Client.new(
          Rails.application.config.twilio[:account_sid],
          Rails.application.config.twilio[:auth_token]
        )

        message = client.messages.create(
          from: Rails.application.config.twilio[:from_number],
          to: @recipient.phone,
          body: sms_message
        )

        { success: true, sid: message.sid }
      rescue Twilio::REST::RestError => e
        Rails.logger.error "SMS delivery failed: #{e.message}"
        { success: false, error: e.message }
      end
    end

  def send_email
    return { success: false, error: 'No email address' } unless @recipient&.email.present?

    begin
      # Get the raw gift card code for email delivery
      raw_code = @gift_card.raw_code || @gift_card.generate_code!
      
      # Try deliver_later first, fallback to deliver_now if Sidekiq not available
      mail = GiftCardMailer.deliver_gift_card(@gift_card, raw_code)
      
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
        🎁 You've received a REM gift card!

        💰 Amount: #{@gift_card.currency} #{@gift_card.amount / 100.0}
        👤 From: #{@sender.name}

        🎫 Your gift card code: #{raw_code}

        📱 Show this code to any participating merchant
        ⏰ No expiration - use anytime!

        Thank you for using REM! 🚀
      MESSAGE
    end

    def sms_message
      raw_code = @gift_card.raw_code || @gift_card.generate_code!
      <<~MESSAGE
        🎁 REM Gift Card Received!

        Amount: #{@gift_card.currency} #{@gift_card.amount / 100.0}
        From: #{@sender.name}

        Code: #{raw_code}

        Show this code to any merchant
        No expiration - use anytime!

        Thanks for using REM!
      MESSAGE
    end


    def update_delivery_flags(results)
      updates = {}
      updates[:sent_via_whatsapp] = true if results[:whatsapp]&.dig(:success)
      updates[:sent_via_sms] = true if results[:sms]&.dig(:success)
      updates[:sent_via_email] = true if results[:email]&.dig(:success)

      @gift_card.update!(updates) if updates.any?
    end
  end
end
