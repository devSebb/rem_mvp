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
      flash[:alert] = "Ingresa un monto de reembolso válido."
      redirect_to new_admin_gift_card_refund_path(@gift_card) and return
    end

    # Friendly pre-check; Refunds::IssueStripeRefund re-validates under the
    # row lock, which is the authoritative enforcement.
    max_refund = @gift_card.refundable_to_buyer_cents
    if refund_amount > max_refund
      flash[:alert] = "El monto excede lo reembolsable (#{format_amount(max_refund, @gift_card.currency)})."
      redirect_to new_admin_gift_card_refund_path(@gift_card) and return
    end

    if reason.blank?
      flash[:alert] = "Indica el motivo del reembolso."
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

      flash[:notice] = "Reembolso Stripe #{refund.id} emitido por #{format_amount(refund_amount, @gift_card.currency)}. " \
                       "El saldo interno se actualiza cuando llegue el webhook de Stripe."
      redirect_to admin_gift_card_path(@gift_card)
    rescue Refunds::IssueStripeRefund::MissingPaymentIntent
      flash[:alert] = "Esta tarjeta no se creó vía Stripe — no hay pago que reembolsar."
      redirect_to new_admin_gift_card_refund_path(@gift_card)
    rescue Refunds::IssueStripeRefund::AlreadyFullyRefunded
      flash[:alert] = "Esta tarjeta ya está cancelada o totalmente reembolsada."
      redirect_to admin_gift_card_path(@gift_card)
    rescue Refunds::IssueStripeRefund::InvalidAmount
      flash[:alert] = "Monto de reembolso inválido."
      redirect_to new_admin_gift_card_refund_path(@gift_card)
    rescue Refunds::IssueStripeRefund::ExceedsRefundableBalance
      flash[:alert] = "El monto excede el saldo reembolsable (el valor ya canjeado no se devuelve al comprador)."
      redirect_to new_admin_gift_card_refund_path(@gift_card)
    rescue Stripe::StripeError => e
      Rails.logger.error "[AdminRefund] Stripe error for gift_card=#{@gift_card.id}: #{e.class} #{e.message}"
      flash[:alert] = "Stripe rechazó el reembolso: #{e.message}"
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
