class Admin::PlatformSettingsController < Admin::BaseController
  before_action :set_settings

  def show
  end

  def update
    if @settings.update(settings_params.merge(updated_by: current_user))
      changes = @settings.saved_changes.except("updated_at", "updated_by_id")
      Rails.logger.warn(
        "[PlatformSettings] Changed by admin_user_id=#{current_user.id}: #{changes.inspect}"
      ) if changes.any?

      redirect_to admin_platform_settings_path, notice: "Configuración actualizada correctamente."
    else
      flash.now[:alert] = "No se pudo guardar la configuración. Revisa los campos."
      render :show, status: :unprocessable_entity
    end
  end

  private

  def set_settings
    @settings = PlatformSetting.current
  end


  def settings_params
    params.require(:platform_setting).permit(
      :buyer_fee_bps, :buyer_fee_fixed_cents, :merchant_commission_bps,
      :purchases_enabled, :min_ios_version, :min_android_version
    )
  end
end
