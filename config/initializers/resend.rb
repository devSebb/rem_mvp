Rails.application.configure do
  resend_api_key = ENV['RESEND_API_KEY']

  if resend_api_key.present?
    Resend.api_key = resend_api_key

    config.action_mailer.delivery_method = :resend
  elsif Rails.env.production?
    Rails.logger&.warn('[Resend] RESEND_API_KEY missing; email delivery disabled/fallback')

    smtp_env_keys = %w[SMTP_ADDRESS SMTP_PORT SMTP_USERNAME SMTP_PASSWORD]

    if smtp_env_keys.all? { |key| ENV[key].present? }
      config.action_mailer.delivery_method = :smtp
      config.action_mailer.smtp_settings = {
        address: ENV['SMTP_ADDRESS'],
        port: ENV['SMTP_PORT'],
        domain: ENV['SMTP_DOMAIN'] || ENV['APP_HOST'] || 'papayal.com',
        user_name: ENV['SMTP_USERNAME'],
        password: ENV['SMTP_PASSWORD'],
        authentication: ENV['SMTP_AUTH_METHOD'] || 'plain',
        enable_starttls_auto: ENV.fetch('SMTP_ENABLE_STARTTLS_AUTO', 'true') != 'false'
      }
    else
      # No email provider configured — safe no-op in production
      config.action_mailer.delivery_method = :test
    end
  else
    # Development/test: write to tmp/mail for local inspection
    config.action_mailer.delivery_method = :file
    config.action_mailer.file_settings = {
      location: Rails.root.join('tmp', 'mail')
    }
  end
end
