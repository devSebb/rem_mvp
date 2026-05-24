class Admin::RefundsController < ApplicationController
  before_action :ensure_admin_or_merchant
  before_action :set_gift_card, only: [:new, :create]

  def new
    authorize @gift_card, :refund?

    # Buyer refund cap: original purchase amount minus anything already
    # refunded. Redemption-side reversals (Type A) go through a separate
    # merchant-facing endpoint, not this controller.
    @already_refunded = @gift_card.transactions.where(txn_type: :refund, status: :succeeded).sum(:amount)
    @max_refund_amount = @gift_card.amount.to_i - @already_refunded.to_i
  end

  def create
    authorize @gift_card, :refund?

    refund_amount = params[:refund_amount]&.to_f&.*(100)&.to_i # Convert to cents
    reason = params[:reason]&.strip

    if refund_amount.nil? || refund_amount <= 0
      flash[:alert] = 'Please enter a valid refund amount.'
      redirect_to new_admin_refund_path(@gift_card) and return
    end

    already_refunded = @gift_card.transactions.where(txn_type: :refund, status: :succeeded).sum(:amount)
    max_refund = @gift_card.amount.to_i - already_refunded.to_i
    if refund_amount > max_refund
      flash[:alert] = "Refund amount exceeds remaining refundable amount (#{format_amount(max_refund, @gift_card.currency)})."
      redirect_to new_admin_refund_path(@gift_card) and return
    end

    if reason.blank?
      flash[:alert] = 'Please provide a reason for the refund.'
      redirect_to new_admin_refund_path(@gift_card) and return
    end

    # Issue the refund at Stripe. Internal balance reconciliation runs
    # asynchronously via the charge.refunded webhook (single code path,
    # see Refunds::IssueStripeRefund).
    begin
      refund = Refunds::IssueStripeRefund.call(
        gift_card: @gift_card,
        amount_cents: refund_amount,
        reason: reason,
        actor: current_user
      )

      flash[:notice] = "Stripe refund #{refund.id} issued for #{format_amount(refund_amount, @gift_card.currency)}. " \
                       "Internal balance updates when the charge.refunded webhook arrives."
      redirect_to gift_card_path(@gift_card)
    rescue Refunds::IssueStripeRefund::MissingPaymentIntent
      flash[:alert] = "This gift card was not created via Stripe — no payment to refund."
      redirect_to new_admin_refund_path(@gift_card)
    rescue Refunds::IssueStripeRefund::AlreadyFullyRefunded
      flash[:alert] = "This card is already canceled or fully refunded."
      redirect_to gift_card_path(@gift_card)
    rescue Refunds::IssueStripeRefund::InvalidAmount
      flash[:alert] = "Invalid refund amount."
      redirect_to new_admin_refund_path(@gift_card)
    rescue Stripe::StripeError => e
      Rails.logger.error "[AdminRefund] Stripe error for gift_card=#{@gift_card.id}: #{e.class} #{e.message}"
      flash[:alert] = "Stripe rejected the refund: #{e.message}"
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
