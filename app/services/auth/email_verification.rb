module Auth
  # Verifies that a fresh signup controls the email address they registered
  # with, before any auth tokens are issued ("block until verified").
  #
  # Mirrors Auth::ClaimVerification's OTP mechanics (SHA-256 digest storage,
  # TTL, resend throttle, attempt cap) but is email-only and, on success,
  # stamps email_verified_at so the account can log in.
  #
  # Flow:
  #   request!(user) — generates a 6-digit code, stores only its digest, and
  #     emails it. Throttled to one send per RESEND_INTERVAL; a throttled
  #     call is a no-op that still returns delivery info (with
  #     :retry_in_seconds) so the endpoint stays idempotent.
  #   verify!(user, otp) — raises Expired / Invalid / TooManyAttempts. On
  #     success clears the OTP columns and sets email_verified_at.
  class EmailVerification
    OTP_TTL = 10.minutes
    RESEND_INTERVAL = 60.seconds
    MAX_ATTEMPTS = 5

    class Error < StandardError; end
    class Expired < Error; end
    class TooManyAttempts < Error; end

    class Invalid < Error
      attr_reader :attempts_remaining

      def initialize(attempts_remaining)
        @attempts_remaining = attempts_remaining
        super("Invalid email verification code (#{attempts_remaining} attempts remaining)")
      end
    end

    class << self
      def request!(user)
        new(user).request!
      end

      def verify!(user, otp)
        new(user).verify!(otp)
      end
    end

    def initialize(user)
      @user = user
    end

    # Generates + emails a fresh code, or no-ops when one was sent less than
    # RESEND_INTERVAL ago. Returns { masked_email:[, retry_in_seconds:] }.
    def request!
      if throttled?
        return delivery_details.merge(retry_in_seconds: retry_in_seconds)
      end

      otp = generate_otp
      @user.update_columns(
        email_otp_digest: digest(otp),
        email_otp_sent_at: Time.current,
        email_otp_attempts: 0,
        updated_at: Time.current
      )

      deliver(otp)
      delivery_details
    end

    # Validates the submitted code against the stored digest. Raises Expired
    # when no live code exists or the TTL passed, Invalid (with
    # attempts_remaining) on a wrong code, and TooManyAttempts once
    # MAX_ATTEMPTS wrong codes invalidate the digest (forcing a resend). On
    # success, clears the OTP columns and marks the email verified.
    def verify!(otp)
      raise Expired if @user.email_otp_digest.blank? || @user.email_otp_sent_at.blank?
      raise Expired if @user.email_otp_sent_at <= OTP_TTL.ago

      if ActiveSupport::SecurityUtils.secure_compare(digest(otp.to_s), @user.email_otp_digest)
        mark_verified!
        return true
      end

      attempts = @user.email_otp_attempts + 1
      if attempts >= MAX_ATTEMPTS
        clear_otp!
        raise TooManyAttempts
      end

      @user.update_columns(email_otp_attempts: attempts, updated_at: Time.current)
      raise Invalid.new(MAX_ATTEMPTS - attempts)
    end

    private

    def throttled?
      @user.email_otp_sent_at.present? && @user.email_otp_sent_at > RESEND_INTERVAL.ago
    end

    def retry_in_seconds
      remaining = RESEND_INTERVAL - (Time.current - @user.email_otp_sent_at)
      remaining.ceil.clamp(0, RESEND_INTERVAL.to_i)
    end

    def generate_otp
      format("%06d", SecureRandom.random_number(1_000_000))
    end

    def digest(otp)
      Digest::SHA256.hexdigest(otp)
    end

    def mark_verified!
      @user.update_columns(
        email_verified_at: Time.current,
        email_otp_digest: nil,
        email_otp_sent_at: nil,
        email_otp_attempts: 0,
        updated_at: Time.current
      )
    end

    def clear_otp!
      @user.update_columns(
        email_otp_digest: nil,
        email_otp_sent_at: nil,
        email_otp_attempts: 0,
        updated_at: Time.current
      )
    end

    def deliver(otp)
      mail = EmailVerificationMailer.verify_email(@user.id, otp)
      begin
        mail.deliver_later
      rescue NoMethodError, Redis::CannotConnectError => e
        Rails.logger.warn "[EmailVerification] deliver_later unavailable (#{e.class}); sending inline"
        mail.deliver_now
      end
    end

    def delivery_details
      { masked_email: mask_email(@user.email) }
    end

    def mask_email(email)
      return nil if email.blank?

      local, _, domain = email.partition("@")
      "#{local[0]}•••@#{domain}"
    end
  end
end
