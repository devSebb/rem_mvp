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
          role: user.role,
          avatar_url: attachment_url(user.avatar),
          avatar_thumb_url: attachment_variant_url(user.avatar, resize_to_limit: [128, 128])
        }
      end
    end
  end
end

