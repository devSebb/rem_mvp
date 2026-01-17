class PasswordResetMailer < ApplicationMailer
  default from: ENV['DEFAULT_FROM_EMAIL'] || 'papayalapp@gmail.com'

  def reset_password_instructions(user, token)
    @user = user
    @token = token
    @reset_url = build_reset_url(token)

    mail(
      to: @user.email,
      subject: "Reset your REM password"
    )
  end

  private

  def build_reset_url(token)
    host = ENV['APP_HOST'] || 'localhost:3000'
    protocol = Rails.env.production? ? 'https' : 'http'
    port = Rails.env.development? ? ':3000' : ''
    
    "#{protocol}://#{host}#{port}/api/v1/auth/reset_password?token=#{token}"
  end
end

