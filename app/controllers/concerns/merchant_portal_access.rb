# Gate for every Merchant:: web controller. A user may use the portal only if
# they have the merchant role, an associated Merchant record, and that
# merchant is active. Suspension previously only blocked the merchant API
# (Api::V1::MerchantBaseController); the web portal kept working, including
# redemptions, refunds and bank-account (IBAN) edits.
module MerchantPortalAccess
  extend ActiveSupport::Concern

  included do
    before_action :ensure_merchant
  end

  private

  def ensure_merchant
    unless current_user&.merchant? && current_user.merchant.present?
      flash[:alert] = "Necesitas una cuenta de comercio para acceder a esta sección."
      redirect_to root_path
      return
    end

    return if current_user.merchant.active?

    Rails.logger.warn "[MerchantPortal] blocked suspended merchant_id=#{current_user.merchant.id} user_id=#{current_user.id}"
    sign_out(current_user)
    redirect_to new_user_session_path,
                alert: "Tu comercio está suspendido. Escríbenos a soporte para más información."
  end
end
