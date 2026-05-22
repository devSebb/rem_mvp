module Users
  # Soft-deletes a user account: anonymizes all PII, revokes sessions and
  # push tokens, purges the avatar, and marks the row deleted. The row
  # itself is kept so gift_cards foreign keys (NOT NULL) remain valid.
  #
  # Single source of truth for account deletion — every entry point
  # (mobile API, web, admin tooling) MUST go through here.
  #
  # Guarantees:
  #   - Atomic: anonymization + session revocation happen in one DB tx.
  #   - Re-auth: caller passes the user's password; we verify before any
  #     destructive write.
  #   - Locked: with_lock on the user prevents concurrent purchases or
  #     profile edits from racing the deletion.
  #   - One-way: no undelete path; password is rerolled to a random
  #     unrecoverable value so password-reset attempts cannot succeed.
  class DeleteAccount
    class Error < StandardError; end
    class MerchantNotAllowed < Error; end
    class AdminNotAllowed < Error; end
    class InvalidPassword < Error; end
    class AlreadyDeleted < Error; end

    def self.call(user:, password:)
      new(user:, password:).call
    end

    def initialize(user:, password:)
      @user = user
      @password = password
    end

    def call
      raise AlreadyDeleted if @user.deleted?
      raise MerchantNotAllowed if @user.merchant?
      raise AdminNotAllowed if @user.admin?
      raise InvalidPassword unless @user.valid_password?(@password.to_s)

      # Capture before anonymization so the confirmation email goes to the
      # real address, not the deleted+<id>@papayal.app placeholder.
      original_email = @user.email
      user_id = @user.id

      ApplicationRecord.transaction do
        @user.with_lock do
          # Re-check inside the lock — guards against TOCTOU where another
          # request flipped state between our pre-check and the transaction.
          raise AlreadyDeleted if @user.deleted?

          revoke_sessions
          deactivate_push_tokens
          purge_avatar
          anonymize_pii
          mark_deleted
        end
      end

      # Email is sent outside the transaction: Resend is a network call
      # that can be slow or fail, and we don't want to roll back deletion
      # if the mailer hiccups. deliver_later queues to Sidekiq so the
      # request returns promptly.
      AccountDeletionMailer.deleted(user_id, original_email).deliver_later

      Rails.logger.info(
        "[AccountDeletion] user_id=#{user_id} deleted_at=#{@user.deleted_at.iso8601}"
      )

      true
    end

    private

    def revoke_sessions
      now = Time.current
      UserSession.where(user_id: @user.id, revoked_at: nil)
                 .update_all(revoked_at: now, last_used_at: now, updated_at: now)
    end

    def deactivate_push_tokens
      @user.push_tokens.destroy_all
    end

    def purge_avatar
      @user.avatar.purge_later if @user.avatar.attached?
    end

    # Wipes every PII column. Email becomes a deterministic placeholder so
    # the unique index is satisfied and the original email is free to be
    # reused at signup. Password is rerolled to a long random value so
    # reset-password attempts cannot land on this row (the row is also
    # excluded from User.active, so login lookups skip it entirely).
    def anonymize_pii
      @user.update_columns(
        email: User.deleted_email_for(@user.id),
        first_name: "Cuenta",
        last_name: "eliminada",
        name: "Cuenta eliminada",
        phone: nil,
        national_id: nil,
        address: nil,
        country_of_residence: nil,
        date_of_birth: nil,
        interests: [],
        encrypted_password: BCrypt::Password.create(SecureRandom.hex(32)),
        reset_password_token: nil,
        reset_password_sent_at: nil,
        remember_created_at: nil,
        updated_at: Time.current
      )
    end

    def mark_deleted
      @user.update_columns(deleted_at: Time.current, updated_at: Time.current)
    end
  end
end
