module Api
  module V1
    module Me
      class PushTokensController < Api::V1::BaseController
        # A device token is unique and belongs to whoever is signed in on that
        # device NOW. Looking it up only among current_user's tokens made a
        # second user on a shared phone hit the unique index (422, swallowed by
        # the app): they never got pushes, while the previous user's kept
        # arriving on this phone. Reassign the row instead.
        def create
          attempts = 0
          begin
            push_token = PushToken.find_or_initialize_by(token: params[:token].to_s)
            push_token.assign_attributes(user: current_user, platform: params[:platform], active: true)
            saved = push_token.save
          rescue ActiveRecord::RecordNotUnique
            attempts += 1
            retry if attempts < 2 # concurrent first registration of the same token
            raise
          end

          if saved
            head :no_content
          else
            render_error(
              code: "push_token.invalid",
              message: push_token.errors.full_messages.to_sentence,
              status: :unprocessable_entity
            )
          end
        end

        def destroy
          current_user.push_tokens.where(token: params[:token]).update_all(active: false)
          head :no_content
        end
      end
    end
  end
end
