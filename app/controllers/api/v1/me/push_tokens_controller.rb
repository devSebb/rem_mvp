module Api
  module V1
    module Me
      class PushTokensController < Api::V1::BaseController
        def create
          push_token = current_user.push_tokens.find_or_initialize_by(token: params[:token])
          push_token.platform = params[:platform]
          push_token.active = true

          if push_token.save
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
