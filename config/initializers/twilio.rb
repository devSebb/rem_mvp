Rails.application.configure do
  if Rails.env.production?
    if ENV['TWILIO_AUTH_TOKEN'].blank? || ENV['TWILIO_ACCOUNT_SID'].blank?
      raise "TWILIO_ACCOUNT_SID and TWILIO_AUTH_TOKEN must be set in production"
    end
  end

  config.twilio = {
    account_sid: ENV['TWILIO_ACCOUNT_SID'],
    auth_token: ENV['TWILIO_AUTH_TOKEN'],
    from_number: ENV['TWILIO_PHONE_NUMBER'],
    whatsapp_number: ENV['TWILIO_WHATSAPP_NUMBER']
  }
end
