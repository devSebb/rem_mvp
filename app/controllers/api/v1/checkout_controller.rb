module Api
  module V1
    class CheckoutController < Api::V1::BaseController
      def validate_kyc
        result = Kyc::CheckoutValidator.call(user: current_user)

        data = {
          ok: result[:ok],
          missing: result[:missing]
        }
        data[:errors] = result[:errors] if result[:errors].present?

        render_success(data:)
      end
    end
  end
end

