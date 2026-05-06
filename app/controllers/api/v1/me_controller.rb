module Api
  module V1
    class MeController < Api::V1::BaseController
      def show
        render_success(data: user_payload(current_user))
      end

      def update
        if current_user.update(me_params)
          render_success(data: user_payload(current_user))
        else
          render_error(
            code: "me.update_failed",
            message: "Update failed",
            status: :unprocessable_entity,
            details: current_user.errors.to_hash(full_messages: true)
          )
        end
      end

      private

      def user_payload(user)
        {
          id: user.id,
          first_name: user.first_name,
          last_name: user.last_name,
          email: user.email,
          name: user.full_name,
          phone: user.phone,
          address: user.address,
          country_of_residence: user.country_of_residence,
          date_of_birth: user.date_of_birth&.iso8601,
          role: user.role,
          avatar_url: attachment_url(user.avatar),
          avatar_thumb_url: attachment_variant_url(user.avatar, resize_to_limit: [128, 128]),
          interests: user.interests,
          preferred_channel: user.preferred_channel
        }
      end

      def me_params
        permitted = params.permit(:address, :country_of_residence, :date_of_birth, :phone, :first_name, :last_name, :preferred_channel, interests: [])
        permitted[:date_of_birth] = permitted[:date_of_birth].presence if permitted.key?(:date_of_birth)
        permitted
      end
    end
  end
end

