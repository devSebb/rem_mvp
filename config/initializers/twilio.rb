Rails.application.configure do
  config.twilio = {
    account_sid: ENV['TWILIO_ACCOUNT_SID'],
    auth_token: ENV['TWILIO_AUTH_TOKEN'],
    from_number: ENV['TWILIO_FROM_NUMBER']
  }
end
