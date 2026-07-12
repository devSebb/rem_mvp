module Api
  module V1
    # Public remote-config for the mobile app: lets limits, fees, feature
    # switches and minimum supported versions change without an app release.
    class ConfigController < Api::V1::BaseController
      skip_before_action :authenticate_user_from_token!

      def show
        settings = PlatformSetting.current

        render_success(data: {
          purchases_enabled: settings.purchases_enabled,
          min_supported_version: {
            ios: settings.min_ios_version,
            android: settings.min_android_version
          },
          fees: {
            buyer_fee_bps: settings.buyer_fee_bps,
            buyer_fee_fixed_cents: settings.buyer_fee_fixed_cents
          },
          gift_card_limits: {
            min_cents: 100,
            max_cents: GiftCard::MAX_AMOUNT_CENTS
          }
        })
      end
    end
  end
end
