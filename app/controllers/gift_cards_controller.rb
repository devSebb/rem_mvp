require 'bigdecimal'

class GiftCardsController < ApplicationController
  before_action :set_gift_card, only: [:show]

  def index
    @gift_cards = policy_scope(GiftCard).includes(:sender, :recipient, :merchant).order(created_at: :desc)
    # Track owner activity once on HTML wallet load to avoid duplicate writes
    # when the page immediately requests JSON data.
    if request.format.html? && current_user.present?
      gift_card_ids = @gift_cards.pluck(:id)
      GiftCard.where(id: gift_card_ids).update_all(last_owner_activity_at: Time.current) if gift_card_ids.any?
    end

    respond_to do |format|
      format.html
      format.json do
        render json: @gift_cards.as_json(include: [:sender, :recipient, :merchant])
      end
    end
  end

  def show
    authorize @gift_card
    # Track owner activity for balance check (only if current_user is owner)
    @gift_card.touch_owner_activity! if current_user.present? && (current_user == @gift_card.sender || current_user == @gift_card.recipient)
  end

  def new
    authorize GiftCard, :create?
    @purchases_in_last_24h = current_user ? GiftCardPurchaseLimiter.purchases_in_last_24h(user: current_user) : 0
    @purchase_limit = GiftCardPurchaseLimiter::MAX_PURCHASES_PER_24H
  end

  def checkout
    authorize GiftCard, :checkout?

    kyc_result = Kyc::CheckoutValidator.call(user: current_user)
    if kyc_result[:missing].present?
      missing_labels = {
        'address' => 'dirección',
        'country_of_residence' => 'país de residencia',
        'date_of_birth' => 'fecha de nacimiento'
      }
      missing_readable = kyc_result[:missing].map { |f| missing_labels[f] || f }.join(', ')
      flash[:alert] = "Para comprar tarjetas de regalo, completa tu perfil: #{missing_readable}."
      redirect_to edit_user_registration_path(anchor: 'kyc-section') and return
    end
    
    amount_input = params[:amount_cents].to_s
    amount_cents = begin
      (BigDecimal(amount_input) * 100).to_i
    rescue ArgumentError, TypeError
      0
    end
    currency = params[:currency] || 'USD'
    recipient_phone = params[:recipient_phone]
    recipient_email = params[:recipient_email]
    recipient_name = params[:recipient_name]
    merchant_id_param = params[:merchant_id]
    merchant_id_value = merchant_id_param.to_s.strip

    if amount_cents <= 0
      flash[:alert] = 'Amount must be greater than 0'
      redirect_to new_gift_card_path and return
    end

    if amount_cents < 100
      flash[:alert] = 'Amount must be at least $1.00'
      redirect_to new_gift_card_path and return
    end

    if amount_cents > GiftCard::MAX_AMOUNT_CENTS
      flash[:alert] = "El monto máximo por tarjeta de regalo es $#{GiftCard::MAX_AMOUNT_CENTS / 100.0} USD"
      redirect_to new_gift_card_path and return
    end

    # Check purchase limit (5 gift cards per 24 hours)
    limit_check = GiftCardPurchaseLimiter.can_purchase?(user: current_user)
    unless limit_check[:allowed]
      flash[:alert] = "Has alcanzado el límite de #{limit_check[:limit]} tarjetas de regalo en las últimas 24 horas. Por favor intenta de nuevo mañana."
      redirect_to new_gift_card_path and return
    end

    if recipient_phone.blank? && recipient_email.blank?
      flash[:alert] = 'Recipient phone or email is required'
      redirect_to new_gift_card_path and return
    end

    if merchant_id_value.blank?
      flash[:alert] = 'Merchant is required'
      redirect_to new_gift_card_path and return
    end

    unless merchant_id_value.match?(/\A\d+\z/)
      flash[:alert] = 'Please select a valid merchant'
      redirect_to new_gift_card_path and return
    end

    merchant_id = Integer(merchant_id_value) rescue nil
    unless merchant_id
      flash[:alert] = 'Please select a valid merchant'
      redirect_to new_gift_card_path and return
    end

    merchant = Merchant.find_by(id: merchant_id)
    unless merchant
      flash[:alert] = 'Please select a valid merchant'
      redirect_to new_gift_card_path and return
    end

    begin
      session = Stripe::Checkout::Session.create(
      payment_method_types: ['card'],
      line_items: [{
        price_data: {
          currency: currency.downcase,
          product_data: { name: "Gift Card for #{recipient_name}" },
          unit_amount: amount_cents,
        },
        quantity: 1,
      }],
      mode: 'payment',
      success_url: success_gift_cards_url + "?session_id={CHECKOUT_SESSION_ID}",
      cancel_url: cancel_gift_cards_url,
      metadata: {
        sender_id: current_user.id,
        recipient_email: recipient_email,
        recipient_phone: recipient_phone,
        recipient_name: recipient_name,
        merchant_id: merchant.id
      }
    )


      redirect_to session.url, allow_other_host: true
    rescue => e
      Rails.logger.error "Stripe checkout error: #{e.message}"
      flash[:alert] = 'Unable to process payment. Please try again.'
      redirect_to new_gift_card_path
    end
  end

  def success
    @session_id = params[:session_id]
    if @session_id.present?
      # Try to find gift card - webhook might not have arrived yet
      @gift_card = GiftCard.find_by(checkout_session_id: @session_id)
      
      # If not found, try once more without blocking (webhook may have just completed)
      @gift_card = GiftCard.find_by(checkout_session_id: @session_id) unless @gift_card
      
      # Log for debugging
      if @gift_card
        Rails.logger.info "✅ Success page: Found gift card #{@gift_card.id} for session #{@session_id}"
      else
        Rails.logger.warn "⚠️ Success page: Gift card not found for session #{@session_id}"
        Rails.logger.warn "   This usually means the webhook hasn't arrived yet. Check if Stripe CLI is running."
      end
    end
  end

  def cancel
    flash[:notice] = 'Payment was cancelled. You can try again anytime.'
    redirect_to new_gift_card_path
  end

  private

  def set_gift_card
    @gift_card = GiftCard.find(params[:id])
  end
end
