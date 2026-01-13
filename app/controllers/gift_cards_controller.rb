require 'bigdecimal'

class GiftCardsController < ApplicationController
  before_action :set_gift_card, only: [:show]

  def index
    @gift_cards = policy_scope(GiftCard).includes(:sender, :recipient, :merchant).order(created_at: :desc)
  end

  def show
    authorize @gift_card
  end

  def new
    authorize GiftCard, :create?
  end

  def checkout
    authorize GiftCard, :checkout?

    kyc_result = Kyc::CheckoutValidator.call(user: current_user)
    if kyc_result[:missing].present?
      flash[:alert] = "Please complete your details (#{kyc_result[:missing].join(', ')}) before checkout."
      redirect_to new_gift_card_path and return
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
      
      # If not found, wait a moment and try again (webhook might be processing)
      unless @gift_card
        sleep(1) # Give webhook a moment to process
        @gift_card = GiftCard.find_by(checkout_session_id: @session_id)
      end
      
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
