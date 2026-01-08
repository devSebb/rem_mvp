module Api
  module V1
    module Me
      class AvatarsController < Api::V1::BaseController
        def create
          avatar_file = params.require(:avatar)
          current_user.avatar.attach(avatar_file)

          unless current_user.valid?
            current_user.avatar.purge if current_user.avatar.attached?
            return render_error(
              code: "avatar.upload_failed",
              message: current_user.errors.full_messages.to_sentence,
              status: :unprocessable_entity
            )
          end

          render_success(
            data: {
              avatar_url: attachment_url(current_user.avatar),
              avatar_thumb_url: attachment_variant_url(current_user.avatar, resize_to_limit: [128, 128])
            }
          )
        end
      end
    end
  end
end

