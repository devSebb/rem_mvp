module Auth
  class RequestPasswordReset
    def self.call(email:)
      new(email:).call
    end

    def initialize(email:)
      @email = email.to_s.strip.downcase
    end

    def call
      # User.active excludes soft-deleted accounts so a deleted user
      # cannot regain access via password reset.
      user = User.active.find_by(email: @email)

      # Always return success to prevent email enumeration
      # Only send email if user exists
      if user
        send_reset_email(user)
      end

      { success: true, message: "If an account exists with that email, password reset instructions have been sent." }
    end

    private

    attr_reader :email

    def send_reset_email(user)
      # Generate reset token using Devise's recoverable module
      # This method sets reset_password_token and reset_password_sent_at
      raw_token = user.send(:set_reset_password_token)
      
      # Send email using our custom mailer
      PasswordResetMailer.reset_password_instructions(user, raw_token).deliver_later
      
      Rails.logger.info("Password reset email sent to #{user.email}")
    rescue => e
      Rails.logger.error("Failed to send password reset email to #{user.email}: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
      # Don't raise - we want to return success to prevent email enumeration
    end
  end
end

