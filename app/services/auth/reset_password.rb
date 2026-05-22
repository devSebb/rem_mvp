module Auth
  class ResetPassword
    def self.call(reset_token:, password:, password_confirmation:)
      new(reset_token:, password:, password_confirmation:).call
    end

    def initialize(reset_token:, password:, password_confirmation:)
      @reset_token = reset_token
      @password = password
      @password_confirmation = password_confirmation
    end

    def call
      user = find_user_by_reset_token
      raise PasswordResetError.new(code: "auth.invalid_token", message: "Invalid or expired reset token") unless user

      validate_password_reset_time(user)
      update_password(user)
      
      { success: true, message: "Password has been reset successfully" }
    rescue PasswordResetError => e
      raise
    rescue => e
      Rails.logger.error("Password reset failed: #{e.message}")
      raise PasswordResetError.new(code: "auth.reset_failed", message: "Failed to reset password")
    end

    private

    attr_reader :reset_token, :password, :password_confirmation

    def find_user_by_reset_token
      # Devise stores reset_password_token as a digest
      # We need to find the user and verify the token
      digest = Devise.token_generator.digest(User, :reset_password_token, reset_token)
      # User.active excludes soft-deleted accounts. Anonymization already
      # nullifies reset_password_token, but this guards defense-in-depth.
      user = User.active.find_by(reset_password_token: digest)
      
      # Also validate the token hasn't expired
      if user && user.reset_password_sent_at
        reset_within = 6.hours
        if user.reset_password_sent_at < reset_within.ago
          raise PasswordResetError.new(
            code: "auth.token_expired",
            message: "Reset token has expired. Please request a new password reset."
          )
        end
      end
      
      user
    end

    def validate_password_reset_time(user)
      # Validation is now done in find_user_by_reset_token
      # This method is kept for backwards compatibility but does nothing
      true
    end

    def update_password(user)
      user.password = password
      user.password_confirmation = password_confirmation
      
      unless user.save
        errors = user.errors.full_messages.join(", ")
        raise PasswordResetError.new(
          code: "auth.password_invalid",
          message: "Password validation failed: #{errors}",
          details: user.errors.to_hash(full_messages: true)
        )
      end

      # Clear the reset token after successful password change
      user.update_columns(
        reset_password_token: nil,
        reset_password_sent_at: nil
      )
    end
  end

  class PasswordResetError < StandardError
    attr_reader :code, :status, :details

    def initialize(code:, message:, status: :unprocessable_entity, details: nil)
      super(message)
      @code = code
      @status = status
      @details = details
    end
  end
end

