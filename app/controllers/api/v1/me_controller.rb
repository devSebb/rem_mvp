module Api
  module V1
    class MeController < Api::V1::BaseController
      def show
        render_success(data: user_payload(current_user))
      end

      private

      def user_payload(user)
        {
          id: user.id,
          email: user.email,
          name: user.name,
          phone: user.phone,
          role: user.role
        }
      end
    end
  end
end

