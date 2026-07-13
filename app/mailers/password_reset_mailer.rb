class PasswordResetMailer < ApplicationMailer
  layout "branded_mailer"
  default from: ENV['DEFAULT_FROM_EMAIL'] || 'hola@papayal.app'

  def reset_password_instructions(user, token)
    @user = user
    @token = token
    # Universal link: opens the app's reset screen with the token prefilled
    # when installed; otherwise the papayal.app/reset instructions page.
    @reset_url = AppLinks.reset_url(token)

    mail(
      to: @user.email,
      subject: "Restablece tu contraseña Papayal"
    )
  end
end

