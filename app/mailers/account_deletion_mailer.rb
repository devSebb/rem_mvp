class AccountDeletionMailer < ApplicationMailer
  # Sent after a user account is permanently deleted. We pass user_id +
  # original_email explicitly because by the time this job runs, the user
  # row has been anonymized (email = deleted+<id>@papayal.app), and we
  # need the real address to actually reach the person.
  def deleted(user_id, recipient_email)
    @user_id = user_id
    @support_email = ENV['DEFAULT_FROM_EMAIL'].presence || 'hola@papayal.app'

    mail(
      to: recipient_email,
      subject: "Tu cuenta de Papayal ha sido eliminada"
    )
  end
end
