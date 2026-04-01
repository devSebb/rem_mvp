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
            :first_name,
            :last_name,
            :name,
            :phone,
            :device_id,
            interests: []
          )
        end

        def build_user
          user = User.new

          user.email = signup_params[:email].to_s.downcase if user.respond_to?(:email=)
          user.password = signup_params[:password] if signup_params.key?(:password)
          if signup_params.key?(:password_confirmation)
            user.password_confirmation = signup_params[:password_confirmation]
          end

          user.first_name = extracted_first_name if extracted_first_name.present?
          user.last_name = extracted_last_name if extracted_last_name.present?
          user.phone = signup_params[:phone] if signup_params.key?(:phone)
          user.interests = signup_params[:interests] if signup_params[:interests].present?

          user.role ||= :user if user.respond_to?(:role) && user.role.blank?

          user
        end

        def required_signup_field_errors
          required_fields = {
            first_name: extracted_first_name,
            last_name: extracted_last_name,
            email: signup_params[:email],
            phone: signup_params[:phone]
          }

          missing_fields = required_fields.select { |_field, value| value.blank? }.keys
          return if missing_fields.empty?

          missing_fields.index_with { ["can't be blank"] }
        end

        def extracted_first_name
          signup_params[:first_name].presence || split_name(signup_params[:name]).first
        end

        def extracted_last_name
          signup_params[:last_name].presence || split_name(signup_params[:name]).second
        end

        def split_name(full_name)
          return [] if full_name.blank?

          full_name.to_s.strip.split(/\s+/, 2)
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

