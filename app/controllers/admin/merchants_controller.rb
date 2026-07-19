require "securerandom"

class Admin::MerchantsController < Admin::BaseController
  before_action :set_merchant, only: [:show, :edit, :update, :suspend, :reactivate, :regenerate_secret, :destroy]

  PER_PAGE = 24
  STATUS_FILTERS = %w[all active suspended].freeze
  CARD_FILTERS = %w[all active redeemed held disputed].freeze
  CARDS_PER_PAGE = 20

  def index
    scope = Merchant.includes(:user)

    @filter = STATUS_FILTERS.include?(params[:filter]) ? params[:filter] : "all"
    scope = scope.where(status: @filter) unless @filter == "all"

    @query = params[:q].to_s.strip
    if @query.present?
      like = "%#{ActiveRecord::Base.sanitize_sql_like(@query)}%"
      scope = scope.left_joins(:user).where(
        "merchants.store_name ILIKE :q OR merchants.contact_email ILIKE :q OR merchants.public_key ILIKE :q OR users.name ILIKE :q OR users.email ILIKE :q",
        q: like
      )
    end

    @status_counts = {
      "all" => Merchant.count,
      "active" => Merchant.active.count,
      "suspended" => Merchant.suspended.count
    }

    @total_count = scope.count
    @page = [params[:page].to_i, 1].max
    @total_pages = [(@total_count.to_f / PER_PAGE).ceil, 1].max
    @merchants = scope.order(created_at: :desc)
                      .offset((@page - 1) * PER_PAGE)
                      .limit(PER_PAGE)

    @merchant_stats = batch_merchant_stats(@merchants.map(&:id))

    @created_merchant = Merchant.find_by(id: params[:created_id]) if params[:created_id].present?
    @generated_secret_key = flash[:generated_secret_key].presence || params[:secret]
    @generated_password = flash[:generated_password].presence || params[:password]
  end

  def show
    @user = @merchant.user
    @stats = merchant_stats(@merchant)

    @cards_filter = CARD_FILTERS.include?(params[:cards]) ? params[:cards] : "all"
    cards_scope =
      case @cards_filter
      when "active" then @merchant.gift_cards.active
      when "redeemed" then @merchant.gift_cards.redeemed
      when "held" then @merchant.gift_cards.currently_held
      when "disputed" then @merchant.gift_cards.disputed
      else @merchant.gift_cards
      end

    @cards_total_count = cards_scope.count
    @cards_page = [params[:cards_page].to_i, 1].max
    @cards_total_pages = [(@cards_total_count.to_f / CARDS_PER_PAGE).ceil, 1].max
    @gift_cards = cards_scope.includes(:sender, :recipient)
                             .order(created_at: :desc)
                             .offset((@cards_page - 1) * CARDS_PER_PAGE)
                             .limit(CARDS_PER_PAGE)

    @recent_transactions = Transaction.where(merchant_id: @merchant.id)
                                      .includes(:gift_card, :user)
                                      .order(created_at: :desc)
                                      .limit(15)

    @settlements = @merchant.settlements.order(created_at: :desc).limit(10)
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
      redirect_to admin_merchant_path(@merchant), alert: "No se puede eliminar este comercio porque tiene #{blockers.to_sentence(two_words_connector: ' y ', last_word_connector: ' y ')}. Suspéndelo si quieres ocultarlo."
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
      held_cards: gift_cards.currently_held.count,
      disputed_cards: gift_cards.disputed.count,
      issued_volume_cents: gift_cards.sum(:amount),
      remaining_balance_cents: gift_cards.active.sum(:remaining_balance),
      redemption_volume_cents: Transaction.net_redeemed_cents(merchant_id: merchant.id),
      last_card_at: gift_cards.maximum(:created_at)
    }
  end

  # Per-merchant stats for the index, computed with one grouped query per
  # metric instead of six queries per row.
  def batch_merchant_stats(merchant_ids)
    return {} if merchant_ids.empty?

    cards = GiftCard.where(merchant_id: merchant_ids)
    total_counts = cards.group(:merchant_id).count
    active_counts = cards.active.group(:merchant_id).count
    redeemed_counts = cards.redeemed.group(:merchant_id).count
    issued_volume = cards.group(:merchant_id).sum(:amount)
    active_balance = cards.active.group(:merchant_id).sum(:remaining_balance)
    redeemed_volume = Transaction.net_redeemed_cents_by_merchant
                                 .slice(*merchant_ids)

    merchant_ids.index_with do |id|
      {
        total_cards: total_counts[id].to_i,
        active_cards: active_counts[id].to_i,
        redeemed_cards: redeemed_counts[id].to_i,
        issued_volume_cents: issued_volume[id].to_i,
        remaining_balance_cents: active_balance[id].to_i,
        redemption_volume_cents: redeemed_volume[id].to_i
      }
    end
  end
end
