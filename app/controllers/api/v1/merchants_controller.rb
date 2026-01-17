module Api
  module V1
    class MerchantsController < Api::V1::BaseController
      def index
        merchants = policy_scope(Merchant)
          .includes(logo_attachment: :blob)
          .order(:store_name)

        render_success(data: merchants.map { |merchant| serialize_merchant(merchant) })
      end

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

      private

      def serialize_merchant(merchant)
        {
          id: merchant.id,
          store_name: merchant.store_name,
          name: merchant.name,
          status: merchant.status,
          logo_url: attachment_url(merchant.logo),
          contact_email: merchant.contact_email,
          address: merchant.address,
          created_at: merchant.created_at&.iso8601,
          updated_at: merchant.updated_at&.iso8601
        }
      end
    end
  end
end

