class ClaimVerificationMailer < ApplicationMailer
  layout "branded_mailer"
  # Emails backing Auth::ClaimVerification — the OTP challenge required to
  # claim a pending recipient account, plus the "your account was claimed"
  # notice sent to the original contact channel afterwards.
  #
  # Both are skipped for placeholder addresses (claim+<hash>@papayal.app)
  # since those are synthetic and undeliverable.

  # 6-digit claim code. Primitives only so deliver_later serializes cleanly.
  def claim_otp(user_id, otp)
    @user = User.find(user_id)
    @otp = otp
    @support_email = support_email

    return if @user.placeholder_email?

    mail(
      to: @user.email,
      subject: "Tu código de verificación Papayal"
    )
  end

  # Sent to the ORIGINAL email of a pending recipient once their account
  # was claimed via signup, so the rightful recipient is alerted if
  # someone else took it over. The email is passed explicitly because the
  # user row may already carry the new owner's address.
  def account_claimed(user_id, original_email)
    @user = User.find(user_id)
    @support_email = support_email

    return if original_email.blank?
    return if original_email.start_with?(User::CLAIM_EMAIL_PREFIX)

    mail(
      to: original_email,
      subject: "Tu cuenta Papayal fue activada"
    )
  end

  private

  def support_email
    ENV['DEFAULT_FROM_EMAIL'].presence || 'hola@papayal.app'
  end
end
