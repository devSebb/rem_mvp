class Admin::RefundsController < ApplicationController
  before_action :ensure_admin_or_merchant
  before_action :set_gift_card, only: [:new, :create]

  def new
    authorize @gift_card, :refund?
    
    # Calculate maximum refundable amount
    @total_redeemed = @gift_card.transactions.successful.redemptions.sum(:amount)
    @max_refund_amount = @total_redeemed
  end

  def create
    authorize @gift_card, :refund?
    
    refund_amount = params[:refund_amount]&.to_f&.*(100)&.to_i # Convert to cents
    reason = params[:reason]&.strip
    
    # Validate refund amount
    if refund_amount.nil? || refund_amount <= 0
      flash[:alert] = 'Please enter a valid refund amount.'
      redirect_to new_admin_refund_path(@gift_card) and return
    end

    @total_redeemed = @gift_card.transactions.successful.redemptions.sum(:amount)
    if refund_amount > @total_redeemed
      flash[:alert] = "Refund amount cannot exceed total redeemed amount of #{format_amount(@total_redeemed, @gift_card.currency)}."
      redirect_to new_admin_refund_path(@gift_card) and return
    end

    if reason.blank?
      flash[:alert] = 'Please provide a reason for the refund.'
      redirect_to new_admin_refund_path(@gift_card) and return
    end

    # Process refund
    if @gift_card.refund!(refund_amount: refund_amount, reason: reason, actor: current_user)
      # TODO: Integrate with Stripe refund in Phase 3.1
      flash[:notice] = "Successfully issued refund of #{format_amount(refund_amount, @gift_card.currency)}. Reason: #{reason}"
      redirect_to gift_card_path(@gift_card)
    else
      flash[:alert] = 'Failed to process refund. Please try again.'
      redirect_to new_admin_refund_path(@gift_card)
    end
  end

  private

  def ensure_admin_or_merchant
    unless current_user&.admin? || current_user&.merchant?
      flash[:alert] = 'You must be an admin or merchant to access this area.'
      redirect_to root_path
    end
  end

  def set_gift_card
    @gift_card = GiftCard.find(params[:gift_card_id])
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
