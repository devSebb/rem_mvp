Rails.application.configure do
  account_sid = ENV['TWILIO_ACCOUNT_SID']
  auth_token = ENV['TWILIO_AUTH_TOKEN']

  if account_sid.blank? || auth_token.blank?
    Rails.logger&.warn('[Twilio] Missing TWILIO_ACCOUNT_SID/AUTH_TOKEN; messaging disabled') if Rails.env.production?
  end

  config.twilio = {
    account_sid: account_sid,
    auth_token: auth_token,
    from_number: ENV['TWILIO_PHONE_NUMBER'],
    whatsapp_number: ENV['TWILIO_WHATSAPP_NUMBER']
  }
end
