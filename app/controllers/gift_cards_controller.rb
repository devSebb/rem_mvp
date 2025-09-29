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
    
    amount_cents = params[:amount_cents].to_i
    currency = params[:currency] || 'USD'
    recipient_phone = params[:recipient_phone]
    recipient_email = params[:recipient_email]
    recipient_name = params[:recipient_name]
    merchant_id = params[:merchant_id]

    if amount_cents <= 0
      flash[:alert] = 'Amount must be greater than 0'
      redirect_to new_gift_card_path and return
    end

    if recipient_phone.blank? && recipient_email.blank?
      flash[:alert] = 'Recipient phone or email is required'
      redirect_to new_gift_card_path and return
    end

    begin
      session = StripeCheckout.create_session(
        amount_cents: amount_cents,
        currency: currency,
        metadata: {
          sender_id: current_user.id,
          recipient_phone: recipient_phone,
          recipient_email: recipient_email,
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
      @gift_card = GiftCard.find_by(checkout_session_id: @session_id)
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
