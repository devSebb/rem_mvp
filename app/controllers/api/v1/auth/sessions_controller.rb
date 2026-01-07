module Api
  module V1
    module Auth
      class SessionsController < Api::V1::BaseController
        skip_before_action :authenticate_user_from_token!, only: [:login, :refresh, :logout]

        def login
          user = User.find_by(email: login_params[:email].to_s.downcase)

          unless user&.valid_password?(login_params[:password])
            return render_error(
              code: "auth.invalid_credentials",
              message: "Invalid email or password",
              status: :unauthorized
            )
          end

          tokens = ::Auth::IssueTokens.call(
            user:,
            device_id: login_params[:device_id],
            ip: request.remote_ip,
            user_agent: request.user_agent
          )

          render_tokens(tokens)
        end

        def refresh
          tokens = ::Auth::RefreshTokens.call(
            refresh_token: params.require(:refresh_token),
            ip: request.remote_ip,
            user_agent: request.user_agent
          )

          render_tokens(tokens)
        rescue ::Auth::TokenError => e
          render_error(code: e.code, message: e.message, status: e.status)
        end

        def logout
          ::Auth::RevokeSession.call(refresh_token: params.require(:refresh_token))

          render_success(data: { revoked: true })
        rescue ::Auth::TokenError => e
          render_error(code: e.code, message: e.message, status: e.status)
        end

        def logout_all
          UserSession.where(user: current_user, revoked_at: nil)
                     .update_all(revoked_at: Time.current, updated_at: Time.current, last_used_at: Time.current)

          render_success(data: { revoked: true })
        end

        private

        def login_params
          params.require(:email)
          params.require(:password)
          params.permit(:email, :password, :device_id)
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

