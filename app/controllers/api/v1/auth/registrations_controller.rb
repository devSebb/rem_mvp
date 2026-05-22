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

          # Look up an existing pending recipient first. If a gift card was
          # sent to this phone or email earlier, the User row already exists
          # in pending state; this signup claims it (preserving the link to
          # any waiting gift cards) instead of creating a duplicate.
          pending_user = find_pending_recipient
          user = pending_user || User.new
          was_pending_claim = pending_user.present?

          populate_user_attributes(user)

          if user.save
            if was_pending_claim
              # TODO: when phone/email verification (OTP) ships, send a
              # claim-confirmation alert here so the original recipient is
              # notified if their pending account was claimed by someone
              # else. Architecture stub — real notifier wired in OTP phase.
              Rails.logger.info "[Auth] Claimed pending account user_id=#{user.id} email=#{user.email}"
            end

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

        # Find a pending User record (claimed_at: nil) whose email or phone
        # matches the signup params. Returns nil if none — the signup will
        # then create a brand-new User as before.
        def find_pending_recipient
          email = signup_params[:email].to_s.strip.downcase.presence
          phone = signup_params[:phone].to_s.strip.presence
          return nil if email.blank? && phone.blank?

          scope = User.where(claimed_at: nil)
          if email.present? && phone.present?
            scope.where("LOWER(email) = ? OR phone = ?", email, phone).first
          elsif email.present?
            scope.where("LOWER(email) = ?", email).first
          else
            scope.where(phone: phone).first
          end
        end

        # Populate fields on either a new User or a pending User being claimed.
        # Marks the record as claimed so full-profile validations apply.
        def populate_user_attributes(user)
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
          user.claimed_at = Time.current
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

