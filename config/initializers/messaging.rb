Rails.application.configure do
  config.messaging = {
    # Twilio configuration
    twilio: {
      account_sid: ENV['TWILIO_ACCOUNT_SID'],
      auth_token: ENV['TWILIO_AUTH_TOKEN'],
      from_number: ENV['TWILIO_PHONE_NUMBER'],
      whatsapp_number: ENV['TWILIO_WHATSAPP_NUMBER']
    },
    
    # Email configuration
    email: {
      from: ENV['DEFAULT_FROM_EMAIL'] || 'noreply@rem.com',
      sendgrid_api_key: ENV['SENDGRID_API_KEY']
    },
    
    # App configuration
    app: {
      host: ENV['APP_HOST'] || 'http://localhost:3000'
    }
  }
end
