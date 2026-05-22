module Api
  module V1
    class BaseController < ActionController::API
      include Pundit::Authorization

      before_action :ensure_json_request
      before_action :authenticate_user_from_token!

      rescue_from StandardError, with: :render_internal_error
      rescue_from Pundit::NotAuthorizedError, with: :render_forbidden
      rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
      rescue_from ActionController::ParameterMissing, with: :render_unprocessable_entity

      attr_reader :current_user

      private

      def ensure_json_request
        request.format = :json
      end

      def authenticate_user_from_token!
        scheme, token = request.authorization.to_s.split(" ", 2)
        log_authorization_header(scheme: scheme, token: token)
        unless scheme == "Bearer" && token.present?
          return render_error(
            code: "auth.missing_token",
            message: "Authorization token is required",
            status: :unauthorized
          )
        end

        payload = Jwt::Decode.call(token: token)
        unless payload["type"] == "access"
          return render_error(
            code: "auth.invalid_token_type",
            message: "Access token required",
            status: :unauthorized
          )
        end

        user = User.find_by(id: payload["sub"])
        if user.nil?
          return render_error(
            code: "auth.user_not_found",
            message: "User not found",
            status: :unauthorized
          )
        end

        # Defense-in-depth: sessions are revoked when an account is
        # deleted, but if a still-valid access token reaches us before
        # its TTL we must reject it here too.
        if user.deleted?
          return render_error(
            code: "auth.account_deleted",
            message: "This account has been deleted",
            status: :unauthorized
          )
        end

        @current_user = user
      rescue JWT::ExpiredSignature
        render_error(
          code: "auth.token_expired",
          message: "Access token expired",
          status: :unauthorized
        )
      rescue JWT::DecodeError => e
        render_error(
          code: "auth.invalid_token",
          message: "Invalid token",
          status: :unauthorized,
          details: Rails.env.development? ? e.message : nil
        )
      end

      def log_authorization_header(scheme:, token:)
        return unless Rails.env.development?

        redacted_token =
          if token.present?
            "#{token[0, 8]}... (len=#{token.length})"
          else
            "[blank]"
          end

        Rails.logger.debug("Auth header received (scheme=#{scheme.inspect}, token=#{redacted_token})")
      end

      def render_success(data:, status: :ok)
        render json: { data:, request_id: request.request_id }, status: status
      end

      def render_error(code:, message:, status:, details: nil)
        payload = {
          error: {
            code: code,
            message: message
          },
          request_id: request.request_id
        }
        payload[:error][:details] = details if details.present?
        render json: payload, status: status
      end

      def render_not_found(exception = nil)
        render_error(
          code: "not_found",
          message: "Resource not found",
          status: :not_found,
          details: exception&.message
        )
      end

      def render_unprocessable_entity(exception)
        render_error(
          code: "invalid_parameters",
          message: exception.message,
          status: :unprocessable_entity
        )
      end

      def render_forbidden(_exception)
        render_error(
          code: "forbidden",
          message: "You are not authorized to perform this action",
          status: :forbidden
        )
      end

      def pundit_user
        current_user
      end

      def attachment_url(attachment)
        return nil unless attachment&.attached?

        Rails.application.routes.url_helpers.rails_blob_url(attachment, **url_options_with_host)
      rescue => e
        Rails.logger.warn("Failed to build attachment URL: #{e.class} - #{e.message}")
        nil
      end

      def attachment_variant_url(attachment, resize_to_limit:)
        return nil unless attachment&.attached? && attachment.variable?

        variant = attachment.variant(resize_to_limit: resize_to_limit)
        Rails.application.routes.url_helpers.rails_representation_url(variant.processed, **url_options_with_host)
      rescue => e
        Rails.logger.warn("Failed to build attachment variant URL: #{e.class} - #{e.message}")
        nil
      end

      def url_options_with_host
        host = ENV["APP_HOST"].presence || request&.host || "localhost"
        protocol = ENV["APP_PROTOCOL"].presence || request&.protocol&.delete_suffix("://") || (Rails.env.production? ? "https" : "http")

        options = { host:, protocol: }
        port = request&.port
        options[:port] = port if port && ![80, 443].include?(port)
        options
      end

      def render_internal_error(exception)
        Rails.logger.error("Mobile API error: #{exception.class} - #{exception.message}")
        Rails.logger.error(exception.backtrace.join("\n")) if exception.backtrace

        render_error(
          code: "internal_error",
          message: "Unexpected error",
          status: :internal_server_error
        )
      end
    end
  end
end

