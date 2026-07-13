module Api
  module V1
    module Auth
      # Confirms the 6-digit code emailed to a fresh signup (or an
      # unverified account attempting login), then issues auth tokens.
      # Backs Auth::EmailVerification.
      class EmailVerificationsController < Api::V1::BaseController
        skip_before_action :authenticate_user_from_token!, only: [:verify, :resend]

        # POST /api/v1/auth/verify_email  { email, code, device_id }
        def verify
          user = find_unverified_user
          return render_unverified_not_found if user.nil?

          ::Auth::EmailVerification.verify!(user, params[:code].to_s.strip)

          # Verification is the moment the account becomes "real" — send the
          # welcome now (it was withheld at signup) and hand back tokens.
          WelcomeMailer.welcome(user.id).deliver_later unless user.placeholder_email?

          tokens = ::Auth::IssueTokens.call(
            user:,
            device_id: params[:device_id],
            ip: request.remote_ip,
            user_agent: request.user_agent
          )
          render_tokens(tokens)
        rescue ::Auth::EmailVerification::Invalid => e
          render_error(
            code: "auth.email_otp_invalid",
            message: "Incorrect verification code",
            status: :unprocessable_entity,
            details: { attempts_remaining: e.attempts_remaining }
          )
        rescue ::Auth::EmailVerification::Expired, ::Auth::EmailVerification::TooManyAttempts
          render_error(
            code: "auth.email_otp_expired",
            message: "Verification code expired, request a new one",
            status: :unprocessable_entity
          )
        end

        # POST /api/v1/auth/resend_verification  { email }
        def resend
          user = find_unverified_user
          # Don't reveal whether an unverified account exists for this email;
          # respond the same either way.
          if user
            details = ::Auth::EmailVerification.request!(user)
            return render_success(
              data: {
                masked_email: details[:masked_email],
                resend_available_in: details[:retry_in_seconds] || ::Auth::EmailVerification::RESEND_INTERVAL.to_i
              }
            )
          end

          render_success(data: { masked_email: nil, resend_available_in: ::Auth::EmailVerification::RESEND_INTERVAL.to_i })
        end

        private

        def find_unverified_user
          email = params[:email].to_s.strip.downcase.presence
          return nil if email.blank?

          User.active
              .where("LOWER(email) = ?", email)
              .where(email_verified_at: nil)
              .where.not(claimed_at: nil)
              .first
        end

        def render_unverified_not_found
          render_error(
            code: "auth.email_verification_not_found",
            message: "No pending verification for this email",
            status: :unprocessable_entity
          )
        end

        def render_tokens(tokens)
          render_success(
            data: {
              access_token: tokens[:access_token],
              refresh_token: tokens[:refresh_token],
              expires_in: tokens[:expires_in]
            }
          )
        end
      end
    end
  end
end
