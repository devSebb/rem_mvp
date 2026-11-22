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
      family_revoked = false
      tokens = session.with_lock do
        first_rotation = !session.revoked?
        if !first_rotation && !within_rotation_grace?(session)
          # A token that was ROTATED (not logged out) is being replayed after
          # the grace window. Either the client is very stale or someone copied
          # it. We can't tell which, so end every session from that sign-in:
          # the legitimate user signs in again, a thief loses access.
          family_revoked = revoke_family!(session) if session.replaced_by_id.present?
          next nil # block returns -> the revocation commits; raise below
        end
        # Otherwise a revoked session here is a lost-response retry of a token
        # rotated moments ago: issue a fresh pair; the earlier replacement stays
        # valid (the client may yet hold it).
        Rails.logger.info("[Auth] refresh rotation grace used for session #{session.id}") unless first_rotation

        issued = Auth::IssueTokens.call(
          user:,
          device_id: session.device_id,
          ip: ip.presence || session.ip,
          user_agent: user_agent.presence || session.user_agent,
          family_id: session.family_id
        )
        if first_rotation
          session.update!(
            revoked_at: Time.current,
            last_used_at: Time.current,
            replaced_by: issued[:session],
            family_id: issued[:session].family_id # adopts the family if it predates family_id
          )
        end
        issued
      end

      unless tokens
        Rails.logger.warn("[Auth] refresh token reuse: revoked session family of user #{user.id}") if family_revoked
        raise TokenError.new(code: "auth.refresh_revoked", message: "Refresh token has been revoked")
      end
      tokens
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

    # Revokes every still-active session descended from the same sign-in.
    def revoke_family!(session)
      return false if session.family_id.blank?

      UserSession.active.where(user_id: session.user_id, family_id: session.family_id)
        .update_all(revoked_at: Time.current, updated_at: Time.current)
      true
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
