module Auth
  # Verifies that whoever signs up to claim a pending recipient account
  # (created when a gift card was sent to an email/phone with no account yet)
  # actually controls one of those contact channels.
  #
  # Flow:
  #   request!(user) — generates a 6-digit OTP, stores only its SHA-256
  #     digest, and delivers the code to the pending user's EXISTING
  #     channels (the ones the gift sender used). Throttled to one send
  #     per RESEND_INTERVAL; a throttled call is a no-op that still
  #     returns delivery info (with :retry_in_seconds) so the endpoint
  #     stays idempotent from the client's perspective.
  #   verify!(user, otp) — raises Expired / Invalid / TooManyAttempts.
  #     On success clears the OTP columns; the caller proceeds with the
  #     normal claim path.
  #   notify_claimed!(user, ...) — tells the ORIGINAL contact channels
  #     that the account was claimed, so the real recipient finds out if
  #     someone else took over their pending account.
  class ClaimVerification
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
        super("Invalid claim OTP (#{attempts_remaining} attempts remaining)")
      end
    end

    class << self
      def request!(user)
        new(user).request!
      end

      def verify!(user, otp)
        new(user).verify!(otp)
      end

      def notify_claimed!(user, email:, phone:)
        new(user).notify_claimed!(email:, phone:)
      end
    end

    def initialize(user)
      @user = user
    end

    # Generates + delivers a fresh OTP, or no-ops when one was sent less
    # than RESEND_INTERVAL ago. Returns a details hash for the API
    # response: { channels:, masked_email:, masked_phone:[, retry_in_seconds:] }.
    def request!
      if throttled?
        return delivery_details(predicted_channels).merge(retry_in_seconds: retry_in_seconds)
      end

      otp = generate_otp
      @user.update_columns(
        claim_otp_digest: digest(otp),
        claim_otp_sent_at: Time.current,
        claim_otp_attempts: 0,
        updated_at: Time.current
      )

      delivery_details(deliver(otp))
    end

    # Validates the submitted code against the stored digest.
    # Raises Expired when no live code exists or the TTL passed,
    # Invalid (with attempts_remaining) on a wrong code, and
    # TooManyAttempts once MAX_ATTEMPTS wrong codes invalidate the digest
    # (forcing a resend). On success, clears the OTP columns.
    def verify!(otp)
      raise Expired if @user.claim_otp_digest.blank? || @user.claim_otp_sent_at.blank?
      raise Expired if @user.claim_otp_sent_at <= OTP_TTL.ago

      if ActiveSupport::SecurityUtils.secure_compare(digest(otp.to_s), @user.claim_otp_digest)
        clear_otp!
        return true
      end

      attempts = @user.claim_otp_attempts + 1
      if attempts >= MAX_ATTEMPTS
        # Invalidate the code entirely (sent_at too, so a resend is
        # allowed immediately instead of waiting out the throttle).
        clear_otp!
        raise TooManyAttempts
      end

      @user.update_columns(claim_otp_attempts: attempts, updated_at: Time.current)
      raise Invalid.new(MAX_ATTEMPTS - attempts)
    end

    # Notifies the ORIGINAL contact channels (captured before the signup
    # params overwrote them) that the pending account was claimed.
    def notify_claimed!(email:, phone:)
      if real_email?(email)
        deliver_mail { ClaimVerificationMailer.account_claimed(@user.id, email) }
      end

      if phone.present?
        send_text(phone, claimed_notice_text)
      end
    end

    private

    def throttled?
      @user.claim_otp_sent_at.present? && @user.claim_otp_sent_at > RESEND_INTERVAL.ago
    end

    def retry_in_seconds
      remaining = RESEND_INTERVAL - (Time.current - @user.claim_otp_sent_at)
      remaining.ceil.clamp(0, RESEND_INTERVAL.to_i)
    end

    def generate_otp
      format("%06d", SecureRandom.random_number(1_000_000))
    end

    def digest(otp)
      Digest::SHA256.hexdigest(otp)
    end

    def clear_otp!
      @user.update_columns(
        claim_otp_digest: nil,
        claim_otp_sent_at: nil,
        claim_otp_attempts: 0,
        updated_at: Time.current
      )
    end

    # ── Delivery ─────────────────────────────────────────────────────────

    # Sends the OTP over every existing channel. Returns the list of
    # channel names attempted ("email", "whatsapp", "sms"). Missing Twilio
    # credentials degrade to a logged warning — the phone channel is still
    # reported as attempted so the client UX stays consistent.
    def deliver(otp)
      channels = []

      if real_email?(@user.email)
        deliver_mail { ClaimVerificationMailer.claim_otp(@user.id, otp) }
        channels << "email"
      end

      if @user.phone.present?
        channels << send_text(@user.phone, otp_text(otp))
      end

      channels.compact
    end

    # Channels a (throttled) resend would use — mirrors #deliver without
    # sending. WhatsApp-preferring users are reported as "whatsapp"; we
    # can't know here whether the original send fell back to SMS.
    def predicted_channels
      channels = []
      channels << "email" if real_email?(@user.email)
      channels << (@user.prefers_sms? ? "sms" : "whatsapp") if @user.phone.present?
      channels
    end

    def delivery_details(channels)
      details = { channels: channels }
      details[:masked_email] = mask_email(@user.email) if channels.include?("email")
      if (%w[sms whatsapp] & channels).any?
        details[:masked_phone] = mask_phone(@user.phone)
      end
      details
    end

    # Sends a text over the user's preferred phone channel (WhatsApp first
    # with SMS fallback by default, mirroring Messaging::Notifier).
    # Returns the channel name used ("whatsapp"/"sms").
    def send_text(phone, body)
      if @user.prefers_sms?
        send_sms(phone, body)
        return "sms"
      end

      if send_whatsapp(phone, body)
        "whatsapp"
      else
        Rails.logger.info "[ClaimVerification] WhatsApp delivery failed for user #{@user.id}; falling back to SMS"
        send_sms(phone, body)
        "sms"
      end
    end

    def send_whatsapp(phone, body)
      client = twilio_client(:whatsapp) or return false
      from_number = Messaging::TwilioConfig.whatsapp_number
      unless from_number.present?
        Rails.logger.warn "[ClaimVerification] TWILIO_WHATSAPP_NUMBER missing; whatsapp not sent"
        return false
      end

      client.messages.create(
        from: "whatsapp:#{from_number}",
        to: "whatsapp:#{phone}",
        body: body
      )
      true
    rescue Twilio::REST::RestError => e
      Rails.logger.error "[ClaimVerification] WhatsApp delivery failed: #{e.message}"
      false
    end

    def send_sms(phone, body)
      client = twilio_client(:sms) or return false
      from_number = Messaging::TwilioConfig.from_number
      unless from_number.present?
        Rails.logger.warn "[ClaimVerification] TWILIO_PHONE_NUMBER missing; sms not sent"
        return false
      end

      client.messages.create(from: from_number, to: phone, body: body)
      true
    rescue Twilio::REST::RestError => e
      Rails.logger.error "[ClaimVerification] SMS delivery failed: #{e.message}"
      false
    end

    def twilio_client(channel)
      unless Messaging::TwilioConfig.enabled?
        Rails.logger.warn "[ClaimVerification] Twilio not configured; #{channel} OTP not sent"
        return nil
      end

      client = Messaging::TwilioConfig.client
      Rails.logger.warn "[ClaimVerification] Twilio client unavailable; #{channel} OTP not sent" unless client
      client
    end

    # deliver_later when a queue backend is around, otherwise send inline
    # (same graceful degradation as Messaging::Notifier).
    def deliver_mail
      mail = yield
      begin
        mail.deliver_later
      rescue NoMethodError, Redis::CannotConnectError => e
        Rails.logger.warn "[ClaimVerification] deliver_later unavailable (#{e.class}); sending inline"
        mail.deliver_now
      end
    end

    # ── Copy ─────────────────────────────────────────────────────────────

    def otp_text(otp)
      "Tu código de verificación Papayal es #{otp}. " \
        "Vence en 10 minutos. Si no intentaste crear una cuenta, ignora este mensaje."
    end

    def claimed_notice_text
      "Papayal: tu cuenta fue activada y tus tarjetas de regalo ya están en ella. " \
        "Si no fuiste tú, escríbenos de inmediato a #{support_email}."
    end

    def support_email
      ENV['DEFAULT_FROM_EMAIL'].presence || 'hola@papayal.app'
    end

    # ── Masking ──────────────────────────────────────────────────────────

    def real_email?(email)
      email.present? &&
        !(email.start_with?(User::CLAIM_EMAIL_PREFIX) && email.end_with?("@#{User::CLAIM_EMAIL_DOMAIN}"))
    end

    def mask_email(email)
      return nil if email.blank?

      local, _, domain = email.partition("@")
      "#{local[0]}•••@#{domain}"
    end

    def mask_phone(phone)
      return nil if phone.blank?

      digits = phone.to_s
      return "•••#{digits.last(2)}" if digits.length <= 8

      "#{digits.first(4)}•••#{digits.last(4)}"
    end
  end
end
