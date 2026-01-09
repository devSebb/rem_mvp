module Messaging
  module TwilioConfig
    module_function

    def enabled?
      account_sid.present? && auth_token.present?
    end

    def client
      return unless enabled?

      Twilio::REST::Client.new(account_sid, auth_token)
    end

    def account_sid
      ENV['TWILIO_ACCOUNT_SID'] || twilio_config[:account_sid]
    end

    def auth_token
      ENV['TWILIO_AUTH_TOKEN'] || twilio_config[:auth_token]
    end

    def from_number
      ENV['TWILIO_PHONE_NUMBER'] || twilio_config[:from_number]
    end

    def whatsapp_number
      ENV['TWILIO_WHATSAPP_NUMBER'] || twilio_config[:whatsapp_number]
    end

    def twilio_config
      Rails.application.config.try(:twilio) || {}
    end
  end
end

