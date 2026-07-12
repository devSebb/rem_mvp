module ConsumerWebGate
  extend ActiveSupport::Concern

  included do
    before_action :redirect_consumer_web
  end

  private

  # The consumer experience lives in the mobile app. Shoppers (role: user)
  # who reach web wallet/browse pages are sent to the "coming soon" page;
  # merchants and admins keep their web surfaces.
  def redirect_consumer_web
    return unless user_signed_in?
    return if current_user.admin? || current_user.merchant?

    redirect_to proximamente_path
  end
end
