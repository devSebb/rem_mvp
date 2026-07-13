class EmailVerificationMailer < ApplicationMailer
  layout "branded_mailer"

  # 6-digit code that confirms a fresh signup controls their email address,
  # required before any auth tokens are issued. Backs Auth::EmailVerification.
  # Primitives only so deliver_later serializes cleanly.
  def verify_email(user_id, otp)
    @user = User.find(user_id)
    @otp = otp
    @first_name = @user.first_name.presence || "amigo"
    @support_email = ENV['DEFAULT_FROM_EMAIL'].presence || 'hola@papayal.app'

    return if @user.placeholder_email?

    mail(
      to: @user.email,
      subject: "Tu código de verificación Papayal: #{otp}"
    )
  end
end
