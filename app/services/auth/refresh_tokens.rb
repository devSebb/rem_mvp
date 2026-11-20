module Auth
  class RefreshTokens
    # A rotated refresh token is accepted again for this long, but only while
    # the session that replaced it is still active (no logout, logout-all or
    # password reset since). Covers a lost rotation response without letting a
    # revoked token come back.
    ROTATION_GRACE = 30.seconds

    def self.call(refresh_token:, ip:, user_agent:)
      new(refresh_token:, ip:, user_agent:).call
    end

    def initialize(refresh_token:, ip:, user_agent:)
      @refresh_token = refresh_token
      @ip = ip
      @user_agent = user_agent
    end

    def call
      payload = Jwt::Decode.call(token: refresh_token)
      ensure_refresh_payload!(payload)

      user = User.find_by(id: payload["sub"])
      raise TokenError.new(code: "auth.user_not_found", message: "User not found") unless user
      # Refresh is blocked for deleted accounts. Sessions are already
      # revoked by Users::DeleteAccount; this guards the window before
      # the client wipes its stored refresh token.
      raise TokenError.new(code: "auth.account_deleted", message: "Account deleted") if user.deleted?

      digest = UserSession.digest(refresh_token)
      session = UserSession.find_by(user:, refresh_token_digest: digest)
      raise TokenError.new(code: "auth.invalid_refresh", message: "Invalid refresh token") unless session

      if token_expired?(payload)
        session.with_lock { session.update!(revoked_at: Time.current, last_used_at: Time.current) unless session.revoked? }
        raise TokenError.new(code: "auth.token_expired", message: "Refresh token expired")
      end

      # Revoke + issue in ONE transaction (with_lock): if issuing fails, the
      # old token stays valid instead of leaving the client with nothing.
      session.with_lock do
        first_rotation = !session.revoked?
        if !first_rotation && !within_rotation_grace?(session)
          raise TokenError.new(code: "auth.refresh_revoked", message: "Refresh token has been revoked")
        end
        # Otherwise a revoked session here is a lost-response retry of a token
        # rotated moments ago: issue a fresh pair; the earlier replacement stays
        # valid (the client may yet hold it).
        Rails.logger.info("[Auth] refresh rotation grace used for session #{session.id}") unless first_rotation

        tokens = Auth::IssueTokens.call(
          user:,
          device_id: session.device_id,
          ip: ip.presence || session.ip,
          user_agent: user_agent.presence || session.user_agent
        )
        if first_rotation
          session.update!(revoked_at: Time.current, last_used_at: Time.current, replaced_by: tokens[:session])
        end
        tokens
      end
    rescue JWT::ExpiredSignature
      raise TokenError.new(code: "auth.token_expired", message: "Refresh token expired")
    rescue JWT::DecodeError
      raise TokenError.new(code: "auth.invalid_token", message: "Invalid token")
    end

    private

    attr_reader :refresh_token, :ip, :user_agent

    def within_rotation_grace?(session)
      session.replaced_by_id.present? &&
        session.revoked_at > ROTATION_GRACE.ago &&
        session.replaced_by&.revoked_at.nil?
    end

    def token_expired?(payload)
      payload["exp"].present? && Time.at(payload["exp"].to_i) <= Time.current
    end

    def ensure_refresh_payload!(payload)
      unless payload["type"] == "refresh"
        raise TokenError.new(code: "auth.invalid_token_type", message: "Refresh token required")
      end
    end
  end
end
