class Merchant::ProfilesController < ApplicationController
  before_action :ensure_merchant
  before_action :set_merchant

  def show
  end

  def update
    merchant_attrs = merchant_params.to_h
    logo_file = merchant_attrs.delete(:logo)

    if @merchant.update(merchant_attrs)
      @merchant.logo.attach(logo_file) if logo_file.present?
      flash[:notice] = 'Perfil actualizado correctamente.'
      redirect_to merchant_profile_path
    else
      flash[:alert] = 'No se pudo actualizar el perfil. Revisa los campos.'
      render :show
    end
  end

  private

  def ensure_merchant
    unless current_user&.merchant?
      flash[:alert] = 'You must be a merchant to access this area.'
      redirect_to root_path
    end
  end

  def set_merchant
    @merchant = current_user.merchant
  end

  def merchant_params
    params.require(:merchant).permit(:store_name, :address, :contact_email, :bank_account_iban, :logo)
  end
end
