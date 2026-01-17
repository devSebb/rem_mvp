module Api
  module V1
    module Auth
      class PasswordsController < Api::V1::BaseController
        skip_before_action :authenticate_user_from_token!, only: [:forgot_password, :reset_password]

        def forgot_password
          result = ::Auth::RequestPasswordReset.call(email: forgot_password_params[:email])

          render_success(
            data: {
              message: result[:message]
            }
          )
        rescue => e
          Rails.logger.error("Forgot password error: #{e.message}")
          render_error(
            code: "auth.forgot_password_failed",
            message: "Failed to process password reset request",
            status: :internal_server_error
          )
        end

        def reset_password
          # Accept token from query params (for email links) or request body
          token = params[:token] || reset_password_params[:reset_token]
          
          unless token.present?
            return render_error(
              code: "auth.missing_token",
              message: "Reset token is required",
              status: :unprocessable_entity
            )
          end
          
          result = ::Auth::ResetPassword.call(
            reset_token: token,
            password: reset_password_params[:password],
            password_confirmation: reset_password_params[:password_confirmation]
          )

          render_success(
            data: {
              message: result[:message]
            }
          )
        rescue ::Auth::PasswordResetError => e
          render_error(
            code: e.code,
            message: e.message,
            status: e.status,
            details: e.details
          )
        rescue ActionController::ParameterMissing => e
          render_error(
            code: "auth.missing_parameters",
            message: e.message,
            status: :unprocessable_entity
          )
        rescue => e
          Rails.logger.error("Reset password error: #{e.message}")
          render_error(
            code: "auth.reset_password_failed",
            message: "Failed to reset password",
            status: :internal_server_error
          )
        end

        private

        def forgot_password_params
          params.require(:email)
          params.permit(:email)
        end

        def reset_password_params
          # Token can come from query params, so we don't require it here
          # But we do require password fields
          params.require(:password)
          params.require(:password_confirmation)
          params.permit(:reset_token, :password, :password_confirmation)
        end
      end
    end
  end
end

