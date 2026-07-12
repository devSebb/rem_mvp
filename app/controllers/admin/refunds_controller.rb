class Admin::RefundsController < Admin::BaseController
  before_action :set_gift_card, only: [:new, :create]

  def new
    authorize @gift_card, :stripe_refund?

    # Buyer refund cap: only value that hasn't been redeemed at a merchant
    # or already refunded to the buyer. Redemption-side reversals (Type A)
    # go through a separate merchant-facing endpoint, not this controller.
    @total_redeemed = @gift_card.total_redemptions
    @max_refund_amount = @gift_card.refundable_to_buyer_cents
  end

  def create
    authorize @gift_card, :stripe_refund?

    refund_amount = params[:refund_amount]&.to_f&.*(100)&.to_i # Convert to cents
    reason = params[:reason]&.strip

    if refund_amount.nil? || refund_amount <= 0
      flash[:alert] = 'Please enter a valid refund amount.'
      redirect_to new_admin_gift_card_refund_path(@gift_card) and return
    end

    # Friendly pre-check; Refunds::IssueStripeRefund re-validates under the
    # row lock, which is the authoritative enforcement.
    max_refund = @gift_card.refundable_to_buyer_cents
    if refund_amount > max_refund
      flash[:alert] = "Refund amount exceeds remaining refundable amount (#{format_amount(max_refund, @gift_card.currency)})."
      redirect_to new_admin_gift_card_refund_path(@gift_card) and return
    end

    if reason.blank?
      flash[:alert] = 'Please provide a reason for the refund.'
      redirect_to new_admin_gift_card_refund_path(@gift_card) and return
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
      redirect_to new_admin_gift_card_refund_path(@gift_card)
    rescue Refunds::IssueStripeRefund::AlreadyFullyRefunded
      flash[:alert] = "This card is already canceled or fully refunded."
      redirect_to gift_card_path(@gift_card)
    rescue Refunds::IssueStripeRefund::InvalidAmount
      flash[:alert] = "Invalid refund amount."
      redirect_to new_admin_gift_card_refund_path(@gift_card)
    rescue Refunds::IssueStripeRefund::ExceedsRefundableBalance
      flash[:alert] = "Refund amount exceeds the card's refundable balance (redeemed value cannot be refunded to the buyer)."
      redirect_to new_admin_gift_card_refund_path(@gift_card)
    rescue Stripe::StripeError => e
      Rails.logger.error "[AdminRefund] Stripe error for gift_card=#{@gift_card.id}: #{e.class} #{e.message}"
      flash[:alert] = "Stripe rejected the refund: #{e.message}"
      redirect_to new_admin_gift_card_refund_path(@gift_card)
    end
  end

  private

  # Stripe refunds pay platform money out to buyers — admin only. Merchants
  # reverse their own redemptions via Merchant::TransactionsController.

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
