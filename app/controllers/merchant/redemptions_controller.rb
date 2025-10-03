class Merchant::RedemptionsController < ApplicationController
  before_action :ensure_merchant

  def new
    @gift_card = nil
  end

  def create
    code = params[:code]&.strip&.upcase
    @gift_card = GiftCard.find_active_by_code(code)

    if @gift_card.nil?
      flash[:alert] = 'Gift card not found or already redeemed.'
      redirect_to new_merchant_redemption_path and return
    end

    unless @gift_card.can_be_redeemed?
      flash[:alert] = 'This gift card cannot be redeemed (expired, inactive, or has no remaining balance).'
      redirect_to new_merchant_redemption_path and return
    end

    # Show confirmation page
    redirect_to confirm_merchant_redemptions_path(gift_card_id: @gift_card.id)
  end

  def confirm
    gift_card_id = params[:gift_card_id]
    @gift_card = GiftCard.find(gift_card_id)
  rescue ActiveRecord::RecordNotFound
    flash[:alert] = 'Gift card not found.'
    redirect_to new_merchant_redemption_path
  end

  def redeem
    gift_card_id = params[:gift_card_id]
    redemption_amount = params[:redemption_amount]&.to_f&.*(100)&.to_i # Convert to cents
    @gift_card = GiftCard.find(gift_card_id)

    # Validate redemption amount
    if redemption_amount.nil? || redemption_amount <= 0
      flash[:alert] = 'Please enter a valid redemption amount.'
      redirect_to confirm_merchant_redemptions_path(gift_card_id: @gift_card.id) and return
    end

    if redemption_amount > @gift_card.remaining_balance
      flash[:alert] = "Redemption amount cannot exceed remaining balance of #{format_amount(@gift_card.remaining_balance, @gift_card.currency)}."
      redirect_to confirm_merchant_redemptions_path(gift_card_id: @gift_card.id) and return
    end

    if @gift_card.partial_redeem!(redemption_amount: redemption_amount, merchant: current_user.merchant, actor: current_user)
      flash[:notice] = "Successfully redeemed #{format_amount(redemption_amount, @gift_card.currency)}. Remaining balance: #{format_amount(@gift_card.reload.remaining_balance, @gift_card.currency)}."
      redirect_to success_merchant_redemptions_path(gift_card_id: @gift_card.id)
    else
      flash[:alert] = 'Failed to redeem gift card. Please try again.'
      redirect_to new_merchant_redemption_path
    end
  rescue ActiveRecord::RecordNotFound
    flash[:alert] = 'Gift card not found.'
    redirect_to new_merchant_redemption_path
  end

  def success
    @gift_card = GiftCard.find(params[:gift_card_id]) if params[:gift_card_id]
  rescue ActiveRecord::RecordNotFound
    flash[:alert] = 'Gift card not found.'
    redirect_to new_merchant_redemption_path
  end

  private

  def ensure_merchant
    unless current_user&.merchant?
      flash[:alert] = 'You must be a merchant to access this area.'
      redirect_to root_path
    end
  end

  def format_amount(amount_cents, currency)
    case currency.upcase
    when 'USD'
      "$#{amount_cents / 100.0}"
    when 'EUR'
      "€#{amount_cents / 100.0}"
    else
      "#{amount_cents / 100.0} #{currency}"
    end
  end
end
