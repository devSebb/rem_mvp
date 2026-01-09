Rails.application.configure do
  sendgrid_api_key = ENV['SENDGRID_API_KEY']

  if sendgrid_api_key.present?
    config.action_mailer.delivery_method = :smtp
    config.action_mailer.smtp_settings = {
      address: 'smtp.sendgrid.net',
      port: 587,
      domain: ENV['SENDGRID_DOMAIN'] || ENV['APP_HOST'] || 'rem.com',
      user_name: 'apikey',
      password: sendgrid_api_key,
      authentication: 'plain',
      enable_starttls_auto: true
    }
  elsif Rails.env.production?
    Rails.logger&.warn('[SendGrid] SENDGRID_API_KEY missing; email delivery disabled/fallback')

    smtp_env_keys = %w[SMTP_ADDRESS SMTP_PORT SMTP_USERNAME SMTP_PASSWORD]

    if smtp_env_keys.all? { |key| ENV[key].present? }
      config.action_mailer.delivery_method = :smtp
      config.action_mailer.smtp_settings = {
        address: ENV['SMTP_ADDRESS'],
        port: ENV['SMTP_PORT'],
        domain: ENV['SMTP_DOMAIN'] || ENV['APP_HOST'] || 'rem.com',
        user_name: ENV['SMTP_USERNAME'],
        password: ENV['SMTP_PASSWORD'],
        authentication: ENV['SMTP_AUTH_METHOD'] || 'plain',
        enable_starttls_auto: ENV.fetch('SMTP_ENABLE_STARTTLS_AUTO', 'true') != 'false'
      }
    else
      # Avoid disk writes or crashes when SendGrid/SMTP are absent in production
      config.action_mailer.delivery_method = :test
    end
  else
    # Fallback to file delivery in development/test
    config.action_mailer.delivery_method = :file
    config.action_mailer.file_settings = {
      location: Rails.root.join('tmp', 'mail')
    }
  end
end
