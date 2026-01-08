Rails.application.configure do
  # SendGrid configuration for ActionMailer
  if Rails.env.production?
    required_env = %w[SENDGRID_API_KEY]
    missing = required_env.select { |key| ENV[key].blank? }

    if missing.any?
      raise "Missing required SendGrid environment variables: #{missing.join(', ')}"
    end

    config.action_mailer.delivery_method = :smtp
    config.action_mailer.smtp_settings = {
      address: 'smtp.sendgrid.net',
      port: 587,
      domain: ENV['SENDGRID_DOMAIN'] || ENV['APP_HOST'] || 'rem.com',
      user_name: 'apikey',
      password: ENV['SENDGRID_API_KEY'],
      authentication: 'plain',
      enable_starttls_auto: true
    }
  elsif Rails.env.development? && ENV['SENDGRID_API_KEY'].present?
    # Optional: Use SendGrid in development if API key is provided
    config.action_mailer.delivery_method = :smtp
    config.action_mailer.smtp_settings = {
      address: 'smtp.sendgrid.net',
      port: 587,
      domain: ENV['SENDGRID_DOMAIN'] || ENV['APP_HOST'] || 'rem.com',
      user_name: 'apikey',
      password: ENV['SENDGRID_API_KEY'],
      authentication: 'plain',
      enable_starttls_auto: true
    }
  else
    # Fallback to file delivery in development/test
    config.action_mailer.delivery_method = :file
    config.action_mailer.file_settings = {
      location: Rails.root.join('tmp', 'mail')
    }
  end
end
