module Api
  module V1
    module Auth
      class RegistrationsController < Api::V1::BaseController
        skip_before_action :authenticate_user_from_token!, only: [:create]

        def create
          missing_field_errors = required_signup_field_errors
          if missing_field_errors.present?
            return render_signup_error(details: missing_field_errors)
          end

          user = build_user

          if user.save
            tokens = ::Auth::IssueTokens.call(
              user:,
              device_id: signup_params[:device_id],
              ip: request.ip,
              user_agent: request.user_agent
            )

            render_tokens(tokens)
          else
            render_error(
              code: "auth.signup_failed",
              message: "Signup failed",
              status: :unprocessable_entity,
              details: user.errors.to_hash(full_messages: true)
            )
          end
        end

        private

        def signup_params
          @signup_params ||= params.permit(
            :email,
            :password,
            :password_confirmation,
            :name,
            :phone,
            :national_id,
            :device_id
          )
        end

        def build_user
          user = User.new

          user.email = signup_params[:email].to_s.downcase if user.respond_to?(:email=)
          user.password = signup_params[:password] if signup_params.key?(:password)
          if signup_params.key?(:password_confirmation)
            user.password_confirmation = signup_params[:password_confirmation]
          end

          assign_optional_attribute(user, :name)
          assign_optional_attribute(user, :phone)
          assign_optional_attribute(user, :national_id)

          user.role ||= :user if user.respond_to?(:role) && user.role.blank?

          user
        end

        def assign_optional_attribute(user, attribute)
          return unless signup_params.key?(attribute)

          setter = "#{attribute}="
          user.public_send(setter, signup_params[attribute]) if user.respond_to?(setter)
        end

        def required_signup_field_errors
          required_fields = %i[name phone national_id]
          missing_fields = required_fields.select { |field| signup_params[field].blank? }
          return if missing_fields.empty?

          missing_fields.index_with { ["can't be blank"] }
        end

        def render_signup_error(details:)
          render_error(
            code: "auth.signup_failed",
            message: "Signup failed",
            status: :unprocessable_entity,
            details:
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

