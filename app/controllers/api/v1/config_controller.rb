module Api
  module V1
    # Public remote-config for the mobile app: lets limits, fees, feature
    # switches and minimum supported versions change without an app release.
    class ConfigController < Api::V1::BaseController
      skip_before_action :authenticate_user_from_token!

      def show
        settings = PlatformSetting.current
        caps = settings.load_caps

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
          # COMPAT (old app reads max_cents for the amount picker)
          gift_card_limits: {
            min_cents: GiftCardLoad::MIN_LOAD_CENTS,
            max_cents: caps[:max_load_cents]
          },
          # §8.2 — the §4.1 caps, never hard-coded in the app
          limits: {
            min_load_cents: GiftCardLoad::MIN_LOAD_CENTS,
            max_load_cents: caps[:max_load_cents],
            max_daily_load_per_card_cents: caps[:max_daily_load_per_card_cents],
            max_card_balance_cents: caps[:max_card_balance_cents],
            max_loads_per_card_per_day: caps[:max_loads_per_card_per_day],
            max_daily_load_per_buyer_cents: caps[:max_daily_load_per_buyer_cents],
            max_daily_loads_per_buyer: caps[:max_daily_loads_per_buyer],
            max_30d_load_per_recipient_cents: caps[:max_30d_load_per_recipient_cents],
            max_30d_load_per_buyer_cents: caps[:max_30d_load_per_buyer_cents],
            buyer_refund_window_hours: caps[:buyer_refund_window_hours]
          }
        })
      end
    end
  end
end
