module Api
  module V1
    class MerchantsController < Api::V1::BaseController
      def index
        merchants = policy_scope(Merchant)
          .includes(logo_attachment: :blob)
          .order(:store_name)

        if params[:category].present? && MerchantCategories::VALID_CATEGORIES.include?(params[:category])
          merchants = merchants.where("? = ANY(categories)", params[:category])
        end

        render_success(data: merchants.map { |merchant| serialize_merchant(merchant) })
      end

      def show
        merchant = Merchant.includes(logo_attachment: :blob).find(params[:id])

        # Return 404 for inactive merchants to non-admin users (reduces enumeration)
        unless current_user.admin? || merchant.active?
          raise ActiveRecord::RecordNotFound, "Merchant not found"
        end

        authorize merchant

        render_success(data: serialize_merchant(merchant))
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
          categories: merchant.categories || [],
          coverage_text: merchant.effective_coverage_text,
          partner_redemption: merchant.partner_redemption,
          redemption_partner_label: merchant.partner_redemption? ? merchant.redemption_partner_display : nil,
          created_at: merchant.created_at&.iso8601,
          updated_at: merchant.updated_at&.iso8601
        }
      end
    end
  end
end

