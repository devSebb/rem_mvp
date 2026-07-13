class PasswordResetMailer < ApplicationMailer
  layout "branded_mailer"
  default from: ENV['DEFAULT_FROM_EMAIL'] || 'hola@papayal.app'

  def reset_password_instructions(user, token)
    @user = user
    @token = token

    mail(
      to: @user.email,
      subject: "Restablece tu contraseña Papayal"
    )
  end
end

