class WelcomeMailer < ApplicationMailer
  layout "branded_mailer"

  # Sent once when a new user signs up via API or web. Triggered from the
  # User model's after_create_commit for fresh signups, and called
  # explicitly from the controllers when a pending recipient is claimed
  # (which is an update, not a create, so callbacks don't fire).
  #
  # Skipped for placeholder-email users (pending recipients created via
  # the Stripe webhook) — they have no real email to send to.
  def welcome(user_id)
    @user = User.find(user_id)
    @first_name = @user.first_name.presence || "amigo"
    @support_email = ENV['DEFAULT_FROM_EMAIL'].presence || 'hola@papayal.app'

    return if @user.placeholder_email?

    mail(
      to: @user.email,
      subject: "Bienvenido a Papayal"
    )
  end
end
