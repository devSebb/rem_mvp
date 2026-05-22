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

      # Pre-deletion summary so the mobile UI can warn the user about
      # what they're about to lose (active balance, open cards) and
      # whether the merchant-must-contact-support branch applies.
      def deletion_preview
        active_cards = current_user.received_gift_cards
                                    .where(status: GiftCard.statuses[:active])

        render_success(
          data: {
            balance_cents: active_cards.sum(:remaining_balance).to_i,
            active_card_count: active_cards.count.to_i,
            is_merchant: current_user.merchant?,
            currency: "USD"
          }
        )
      end

      def destroy
        password = params[:password]
        if password.blank?
          return render_error(
            code: "me.password_required",
            message: "Password is required",
            status: :unprocessable_entity
          )
        end

        ::Users::DeleteAccount.call(user: current_user, password: password)

        render_success(data: { deleted: true })
      rescue ::Users::DeleteAccount::InvalidPassword
        render_error(
          code: "me.invalid_password",
          message: "Invalid password",
          status: :unauthorized
        )
      rescue ::Users::DeleteAccount::MerchantNotAllowed
        render_error(
          code: "me.merchant_must_contact_support",
          message: "Las cuentas de comercio deben contactar a soporte para eliminar.",
          status: :forbidden
        )
      rescue ::Users::DeleteAccount::AdminNotAllowed
        render_error(
          code: "me.admin_not_allowed",
          message: "Admin accounts cannot self-delete",
          status: :forbidden
        )
      rescue ::Users::DeleteAccount::AlreadyDeleted
        # Defense-in-depth — base_controller blocks deleted users, but if
        # a race slips through we still return a clean code.
        render_error(
          code: "me.already_deleted",
          message: "Account is already deleted",
          status: :gone
        )
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

