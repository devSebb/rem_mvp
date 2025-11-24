module Api
  module V1
    class MerchantBaseController < ActionController::API
      before_action :authenticate_merchant!

      rescue_from ActionController::ParameterMissing, with: :render_unprocessable_entity
      rescue_from Redemptions::AuthorizeAndCapture::ValidationError, with: :render_unprocessable_entity
      rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

      attr_reader :current_merchant

      private

      def authenticate_merchant!
        scheme, secret = bearer_credentials
        return render_unauthorized("Missing Authorization header") if scheme.nil? && secret.nil?
        return render_unauthorized("Invalid Authorization header") unless scheme == "Bearer" && secret.present?

        digest = Merchant.digest_secret(secret)
        merchant = Merchant.find_by(secret_key_digest: digest)

        unless merchant&.authenticate_secret(secret)
          return render_unauthorized
        end

        if merchant.suspended?
          return render json: { error: "Merchant suspended" }, status: :forbidden
        end

        @current_merchant = merchant
      end

      def bearer_credentials
        header = request.authorization.to_s
        header.split(" ", 2)
      end

      def render_unprocessable_entity(exception)
        render json: { error: exception.message }, status: :unprocessable_entity
      end

      def render_unauthorized(message = "Unauthorized")
        render json: { error: message }, status: :unauthorized
      end

      def render_not_found
        render json: { error: "Not Found" }, status: :not_found
      end
    end
  end
end

