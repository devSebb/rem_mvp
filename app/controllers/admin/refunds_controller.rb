class Admin::RefundsController < Admin::BaseController
  before_action :set_gift_card, only: [:new, :create]

  # Type B refunds are per LOAD (§5.7): the form lists the card's loads with
  # what each can still return to its buyer. `gift_card_load_id` selects one;
  # when absent the latest refundable load is used (old form compat).
  def new
    authorize @gift_card, :stripe_refund?

    @total_redeemed = @gift_card.total_redemptions
    @loads = @gift_card.loads.reject(&:status_canceled?)
    @selected_load = selected_load
    @max_refund_amount = @selected_load&.refundable_cents.to_i
  end

  def create
    authorize @gift_card, :stripe_refund?

    refund_amount = params[:refund_amount]&.to_f&.*(100)&.to_i # Convert to cents
    reason = params[:reason]&.strip
    load = selected_load

    if load.nil?
      flash[:alert] = "Esta tarjeta no tiene recargas reembolsables."
      redirect_to admin_gift_card_path(@gift_card) and return
    end

    if refund_amount.nil? || refund_amount <= 0
      flash[:alert] = "Ingresa un monto de reembolso válido."
      redirect_to new_admin_gift_card_refund_path(@gift_card, gift_card_load_id: load.id) and return
    end

    # Friendly pre-check; Refunds::IssueStripeRefund re-validates under the
    # card lock, which is the authoritative enforcement.
    if refund_amount > load.refundable_cents
      flash[:alert] = "El monto excede lo reembolsable de esta recarga (#{format_amount(load.refundable_cents, @gift_card.currency)})."
      redirect_to new_admin_gift_card_refund_path(@gift_card, gift_card_load_id: load.id) and return
    end

    if reason.blank?
      flash[:alert] = "Indica el motivo del reembolso."
      redirect_to new_admin_gift_card_refund_path(@gift_card, gift_card_load_id: load.id) and return
    end

    begin
      refund = Refunds::IssueStripeRefund.call(load: load, amount_cents: refund_amount, reason: reason, actor: current_user)

      flash[:notice] = "Reembolso Stripe #{refund.id} emitido por #{format_amount(refund_amount, @gift_card.currency)} " \
                       "sobre la recarga ##{load.id}. El saldo interno se actualiza cuando llegue el webhook de Stripe."
      redirect_to admin_gift_card_path(@gift_card)
    rescue Refunds::IssueStripeRefund::MissingPaymentIntent
      flash[:alert] = "Esta recarga no se creó vía Stripe — no hay pago que reembolsar."
      redirect_to new_admin_gift_card_refund_path(@gift_card, gift_card_load_id: load.id)
    rescue Refunds::IssueStripeRefund::AlreadyFullyRefunded
      flash[:alert] = "Esta recarga ya está totalmente reembolsada o cancelada."
      redirect_to admin_gift_card_path(@gift_card)
    rescue Refunds::IssueStripeRefund::LoadDisputed
      flash[:alert] = "Esta recarga tiene una disputa abierta; Stripe no permite reembolsarla."
      redirect_to admin_gift_card_path(@gift_card)
    rescue Refunds::IssueStripeRefund::InvalidAmount
      flash[:alert] = "Monto de reembolso inválido."
      redirect_to new_admin_gift_card_refund_path(@gift_card, gift_card_load_id: load.id)
    rescue Refunds::IssueStripeRefund::ExceedsRefundableBalance
      flash[:alert] = "El monto excede el saldo reembolsable (el valor ya canjeado no se devuelve al comprador)."
      redirect_to new_admin_gift_card_refund_path(@gift_card, gift_card_load_id: load.id)
    rescue Stripe::StripeError => e
      Rails.logger.error "[AdminRefund] Stripe error for gift_card=#{@gift_card.id} load=#{load.id}: #{e.class} #{e.message}"
      flash[:alert] = "Stripe rechazó el reembolso: #{e.message}"
      redirect_to new_admin_gift_card_refund_path(@gift_card, gift_card_load_id: load.id)
    end
  end

  private

  # Stripe refunds pay platform money out to buyers — admin only. Merchants
  # reverse their own redemptions via Merchant::TransactionsController.

  def set_gift_card
    @gift_card = GiftCard.find(params[:gift_card_id])
  end

  def selected_load
    loads = @gift_card.loads.reject(&:status_canceled?)
    if params[:gift_card_load_id].present?
      loads.find { |l| l.id == params[:gift_card_load_id].to_i }
    else
      loads.select { |l| l.payment_intent_id.present? && l.refundable_cents.positive? }.max_by(&:created_at) ||
        loads.select { |l| l.payment_intent_id.present? }.max_by(&:created_at)
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
