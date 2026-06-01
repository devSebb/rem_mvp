module Api
  module V1
    module Public
      class MerchantsController < Api::V1::BaseController
        skip_before_action :authenticate_user_from_token!

        def index
          merchants = Merchant.active
            .includes(logo_attachment: :blob)
            .order(:store_name)

          if params[:category].present? && MerchantCategories::VALID_CATEGORIES.include?(params[:category])
            merchants = merchants.where("? = ANY(categories)", params[:category])
          end

          render_success(data: merchants.map { |merchant| serialize_public_merchant(merchant) })
        end

        def show
          merchant = Merchant.active
            .includes(logo_attachment: :blob)
            .find(params[:id])

          render_success(data: serialize_public_merchant(merchant))
        end

        private

        def serialize_public_merchant(merchant)
          {
            id: merchant.id,
            store_name: merchant.store_name,
            name: merchant.name,
            logo_url: attachment_url(merchant.logo),
            address: merchant.address,
            categories: merchant.categories || []
          }
        end
      end
    end
  end
end
