module Auth
  class RevokeSession
    def self.call(refresh_token:)
      new(refresh_token:).call
    end

    def initialize(refresh_token:)
      @refresh_token = refresh_token
    end

    def call
      payload = Jwt::Decode.call(token: refresh_token)
      ensure_refresh_payload!(payload)

      session = UserSession.find_by(
        user_id: payload["sub"],
        refresh_token_digest: UserSession.digest(refresh_token)
      )

      raise TokenError.new(code: "auth.invalid_refresh", message: "Invalid refresh token") unless session

      session.with_lock do
        if session.revoked?
          raise TokenError.new(code: "auth.refresh_revoked", message: "Refresh token has been revoked")
        end

        session.update!(revoked_at: Time.current, last_used_at: Time.current)
      end

      session
    rescue JWT::ExpiredSignature
      raise TokenError.new(code: "auth.token_expired", message: "Refresh token expired")
    rescue JWT::DecodeError
      raise TokenError.new(code: "auth.invalid_token", message: "Invalid token")
    end

    private

    attr_reader :refresh_token

    def ensure_refresh_payload!(payload)
      unless payload["type"] == "refresh"
        raise TokenError.new(code: "auth.invalid_token_type", message: "Refresh token required")
      end
    end
  end
end

