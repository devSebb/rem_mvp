module Auth
  class RefreshTokens
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

      session.with_lock do
        if session.revoked?
          raise TokenError.new(code: "auth.refresh_revoked", message: "Refresh token has been revoked")
        end

        if token_expired?(payload)
          session.update!(revoked_at: Time.current, last_used_at: Time.current)
          raise TokenError.new(code: "auth.token_expired", message: "Refresh token expired")
        end

        session.update!(
          revoked_at: Time.current,
          last_used_at: Time.current
        )
      end

      Auth::IssueTokens.call(
        user:,
        device_id: session.device_id,
        ip: ip.presence || session.ip,
        user_agent: user_agent.presence || session.user_agent
      )
    rescue JWT::ExpiredSignature
      raise TokenError.new(code: "auth.token_expired", message: "Refresh token expired")
    rescue JWT::DecodeError
      raise TokenError.new(code: "auth.invalid_token", message: "Invalid token")
    end

    private

    attr_reader :refresh_token, :ip, :user_agent

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

