module Api
  module V1
    class MerchantsController < Api::V1::BaseController
      def upload_logo
        merchant = Merchant.find(params[:id])
        authorize merchant, :update_logo?

        merchant.logo.attach(params.require(:logo))

        unless merchant.valid?
          merchant.logo.purge if merchant.logo.attached?
          return render_error(
            code: "merchant.logo_upload_failed",
            message: merchant.errors.full_messages.to_sentence,
            status: :unprocessable_entity
          )
        end

        render_success(
          data: {
            merchant_id: merchant.id,
            merchant_store_name: merchant.store_name,
            merchant_logo_url: attachment_url(merchant.logo)
          }
        )
      end
    end
  end
end

