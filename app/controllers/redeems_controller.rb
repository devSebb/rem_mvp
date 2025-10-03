class RedeemsController < ApplicationController
  before_action :find_gift_card_by_token, only: [:show, :claim]
  before_action :ensure_gift_card_valid, only: [:show, :claim]

  def show
    # Show the redemption form
    @merchants = Merchant.includes(:user).all
  end

  def claim
    @merchant = Merchant.find(params[:merchant_id])
    @otp = params[:otp]

    # Validate OTP
    unless @gift_card.valid_otp?(@otp)
      flash.now[:alert] = 'Invalid or expired redemption code. Please check and try again.'
      @merchants = Merchant.includes(:user).all
      render :show, status: :unprocessable_entity
      return
    end

    # Attempt redemption
    if @gift_card.redeem!(merchant: @merchant, actor: @gift_card.recipient)
      # Consume both tokens after successful redemption
      @gift_card.consume_link_token!
      @gift_card.consume_otp!
      
      redirect_to redeem_success_path, notice: 'Gift card redeemed successfully!'
    else
      flash.now[:alert] = 'Unable to redeem gift card. Please try again or contact support.'
      @merchants = Merchant.includes(:user).all
      render :show, status: :unprocessable_entity
    end
  end

  def success
    # Show success page
  end

  private

  def find_gift_card_by_token
    @gift_card = GiftCard.find_by_link_token(params[:token])
    
    unless @gift_card
      flash[:alert] = 'Invalid or expired redemption link.'
      redirect_to root_path
    end
  end

  def ensure_gift_card_valid
    return unless @gift_card

    unless @gift_card.can_be_redeemed?
      flash[:alert] = 'This gift card cannot be redeemed. It may have already been used or expired.'
      redirect_to root_path
    end
  end
end
