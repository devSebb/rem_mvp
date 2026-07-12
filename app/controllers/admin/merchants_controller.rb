require "securerandom"

class Admin::MerchantsController < Admin::BaseController
  before_action :set_merchant, only: [:show, :edit, :update, :suspend, :reactivate, :regenerate_secret, :destroy]

  def index
    @merchants = Merchant.includes(:user).order(created_at: :desc)
    @created_merchant = Merchant.find_by(id: params[:created_id]) if params[:created_id].present?
    @generated_secret_key = flash[:generated_secret_key].presence || params[:secret]
    @generated_password = flash[:generated_password].presence || params[:password]
  end

  def show
    @user = @merchant.user
    @stats = merchant_stats(@merchant)
    @recent_gift_cards = @merchant.gift_cards.includes(:sender, :recipient).order(created_at: :desc).limit(10)
  end

  def edit
    @user = @merchant.user
  end

  def new
    @merchant = Merchant.new
    @user = User.new(role: :merchant)
  end

  def create
    @user = build_user_from_params
    merchant_attrs = merchant_params.to_h
    logo_file = merchant_attrs.delete(:logo)
    @merchant = Merchant.new(merchant_attrs)
    @merchant.user = @user
    @merchant.contact_email ||= @user.email

    generated_password, password_generated = ensure_password_for(@user)

    if @merchant.save
      @merchant.logo.attach(logo_file) if logo_file.present?
      secret_key = @merchant.generated_secret_key
      flash[:generated_secret_key] = secret_key
      flash[:generated_password] = generated_password if password_generated

      redirect_to admin_merchants_path(created_id: @merchant.id), notice: "Comercio creado correctamente."
    else
      flash.now[:alert] = "No se pudo crear el comercio. Revisa los campos."
      render :new, status: :unprocessable_entity
    end
  end

  def update
    @user = @merchant.user

    user_attrs = user_params.to_h
    user_attrs[:email] = user_attrs[:email].to_s.downcase if user_attrs[:email]
    user_attrs[:phone] = user_attrs[:phone].presence
    user_attrs.compact_blank!

    merchant_attrs = merchant_params.to_h
    logo_file = merchant_attrs.delete(:logo)

    ActiveRecord::Base.transaction do
      @user.update!(user_attrs)
      @merchant.update!(merchant_attrs)
      @merchant.logo.attach(logo_file) if logo_file.present?
    end

    redirect_to admin_merchant_path(@merchant), notice: "Comercio actualizado correctamente."
  rescue ActiveRecord::RecordInvalid
    flash.now[:alert] = "No se pudo actualizar el comercio. Revisa los campos."
    render :edit, status: :unprocessable_entity
  end

  def suspend
    if @merchant.suspended?
      redirect_to admin_merchant_path(@merchant), notice: "El comercio ya estaba suspendido."
      return
    end

    @merchant.suspended!
    redirect_to admin_merchant_path(@merchant), notice: "Comercio suspendido. Ya no aparecerá en la app ni podrá usar la API."
  end

  def reactivate
    if @merchant.active?
      redirect_to admin_merchant_path(@merchant), notice: "El comercio ya estaba activo."
      return
    end

    @merchant.active!
    redirect_to admin_merchant_path(@merchant), notice: "Comercio reactivado. Volverá a aparecer en la app."
  end

  def regenerate_secret
    keys = Merchant.generate_keys!(@merchant)
    flash[:generated_secret_key] = keys[:secret_key]

    redirect_to admin_merchant_path(@merchant), notice: "Nueva clave secreta generada. La clave anterior dejó de funcionar."
  end

  def destroy
    blockers = @merchant.admin_delete_blockers

    if blockers.any?
      redirect_to admin_merchant_path(@merchant), alert: "No se puede eliminar este comercio porque tiene #{blockers.to_sentence}. Suspéndelo si quieres ocultarlo."
      return
    end

    merchant_name = @merchant.store_name
    merchant_user = @merchant.user

    ActiveRecord::Base.transaction do
      if merchant_user&.merchant?
        UserSession.where(user_id: merchant_user.id).delete_all
        merchant_user.destroy!
      else
        @merchant.destroy!
      end
    end

    redirect_to admin_merchants_path, notice: "Comercio #{merchant_name} eliminado correctamente."
  end

  private

  def set_merchant
    @merchant = Merchant.find(params[:id])
  end


  def build_user_from_params
    attrs = user_params.to_h
    attrs[:email] = attrs[:email].to_s.downcase if attrs[:email]
    attrs[:phone] = attrs[:phone].presence
    User.new(attrs.merge(role: :merchant))
  end

  def ensure_password_for(user)
    return [user.password, false] if user.password.present?

    generated_password = SecureRandom.base58(12)
    user.password = generated_password
    user.password_confirmation = generated_password
    [generated_password, true]
  end

  def merchant_params
    params.require(:merchant).permit(:store_name, :address, :contact_email, :bank_account_iban, :avatar_url, :logo, :partner_redemption, :redemption_partner_label, :coverage_text, categories: [])
  end

  def user_params
    params.require(:user).permit(:first_name, :last_name, :email, :phone, :password, :password_confirmation)
  end

  def merchant_stats(merchant)
    gift_cards = merchant.gift_cards
    {
      total_cards: gift_cards.count,
      active_cards: gift_cards.active.count,
      redeemed_cards: gift_cards.redeemed.count,
      issued_volume_cents: gift_cards.sum(:amount),
      remaining_balance_cents: gift_cards.sum(:remaining_balance),
      redemption_volume_cents: merchant.transactions.successful.redemptions.sum(:amount)
    }
  end
end
