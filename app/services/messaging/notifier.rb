module Messaging
  class Notifier
    include Rails.application.routes.url_helpers

    def initialize(gift_card)
      @gift_card = gift_card
      @tokens = gift_card.generate_delivery_tokens!
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
        GiftCardMailer.deliver_gift_card(@gift_card, @tokens).deliver_later
        { success: true }
      rescue => e
        Rails.logger.error "Email delivery failed: #{e.message}"
        { success: false, error: e.message }
      end
    end

    private

    def whatsapp_message
      <<~MESSAGE
        🎁 You've received a REM gift card!

        💰 Amount: #{@gift_card.currency} #{@gift_card.amount / 100.0}
        👤 From: #{@sender.name}

        🔗 Redeem here: #{redeem_url}
        🔐 Your code: #{@tokens[:otp]}

        ⏰ Link expires in 7 days
        ⏰ Code expires in 1 hour

        Thank you for using REM! 🚀
      MESSAGE
    end

    def sms_message
      <<~MESSAGE
        🎁 REM Gift Card Received!

        Amount: #{@gift_card.currency} #{@gift_card.amount / 100.0}
        From: #{@sender.name}

        Redeem: #{redeem_url}
        Code: #{@tokens[:otp]}

        Link expires: 7 days
        Code expires: 1 hour

        Thanks for using REM!
      MESSAGE
    end

    def redeem_url
      "#{ENV['APP_HOST']}/redeem?token=#{@tokens[:link]}"
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
