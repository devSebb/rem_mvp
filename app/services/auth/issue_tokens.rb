require "securerandom"

module Auth
  class IssueTokens
    ACCESS_TTL = 15.minutes
    REFRESH_TTL = 14.days

    # family_id: pass the parent session's family when rotating; a fresh
    # sign-in starts a new family (see Auth::RefreshTokens reuse detection).
    def self.call(user:, device_id: nil, ip: nil, user_agent: nil, family_id: nil)
      new(user:, device_id:, ip:, user_agent:, family_id:).call
    end

    def initialize(user:, device_id:, ip:, user_agent:, family_id:)
      @user = user
      @device_id = device_id
      @ip = ip
      @user_agent = user_agent
      @family_id = family_id.presence || SecureRandom.uuid
    end

    def call
      access_token = Jwt::Encode.call(payload: base_claims.merge(type: "access"), exp: access_expires_at)
      refresh_token = Jwt::Encode.call(payload: refresh_claims, exp: refresh_expires_at)

      session = UserSession.create!(
        user:,
        refresh_token_digest: UserSession.digest(refresh_token),
        device_id: device_id,
        family_id: family_id,
        ip: ip,
        user_agent: user_agent,
        last_used_at: Time.current
      )

      {
        access_token:,
        refresh_token:,
        expires_in: ACCESS_TTL.to_i,
        refresh_expires_in: REFRESH_TTL.to_i,
        session:
      }
    end

    private

    attr_reader :user, :device_id, :ip, :user_agent, :family_id

    def base_claims
      { sub: user.id }
    end

    def refresh_claims
      base_claims.merge(
        type: "refresh",
        jti: SecureRandom.uuid
      )
    end

    def access_expires_at
      ACCESS_TTL.from_now
    end

    def refresh_expires_at
      REFRESH_TTL.from_now
    end
  end
end
