class ContactMailer < ApplicationMailer
  # Delivers messages submitted through the public marketing contact form.
  # Always routed to the Papayal inbox; reply_to is set to the visitor so
  # the team can respond directly from Gmail.
  def contact_message(name, email, message)
    @name = name
    @email = email
    @message = message

    mail(
      to: recipient,
      reply_to: email,
      subject: "[CONTACTO] Nuevo mensaje de #{name}"
    )
  end

  private

  def recipient
    ENV['CONTACT_EMAIL'].presence || 'hola@papayal.app'
  end
end
