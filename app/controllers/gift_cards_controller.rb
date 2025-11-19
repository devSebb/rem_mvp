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
    merchant_id = params[:merchant_id]

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
        merchant_id: merchant_id
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
