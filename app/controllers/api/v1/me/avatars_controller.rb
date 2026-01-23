module Api
  module V1
    module Me
      class AvatarsController < Api::V1::BaseController
        def create
          avatar_file = params.require(:avatar)
          
          # Attach the avatar first
          current_user.avatar.attach(avatar_file)
          
          # Manually validate only the avatar (check size and type)
          # We skip other validations since this is an avatar-only update
          avatar_valid = true
          if current_user.avatar.attached?
            blob = current_user.avatar.blob
            if blob.byte_size > 5.megabytes
              current_user.errors.add(:avatar, "is too large (max 5MB)")
              avatar_valid = false
            elsif !blob.content_type&.start_with?("image/")
              current_user.errors.add(:avatar, "must be an image")
              avatar_valid = false
            end
          end
          
          if avatar_valid
            # Save without running validations on other fields
            # The avatar attachment will be persisted
            current_user.save(validate: false)
            # Reload to ensure we have the latest data including the avatar
            current_user.reload
            
            render_success(
              data: {
                avatar_url: attachment_url(current_user.avatar),
                avatar_thumb_url: attachment_variant_url(current_user.avatar, resize_to_limit: [128, 128])
              }
            )
          else
            # Purge the avatar if validation failed
            current_user.avatar.purge if current_user.avatar.attached?
            render_error(
              code: "avatar.upload_failed",
              message: current_user.errors.full_messages.to_sentence,
              status: :unprocessable_entity
            )
          end
        end
      end
    end
  end
end

