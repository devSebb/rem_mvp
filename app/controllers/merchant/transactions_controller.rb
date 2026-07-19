class Merchant::TransactionsController < ApplicationController
  before_action :ensure_merchant
  before_action :find_gift_card

  def refund
    authorize @gift_card, :refund?

    redemption = @gift_card.transactions.successful.redemptions.find_by!(id: params[:transaction_id], merchant_id: current_user.merchant&.id)
    reason = params[:reason].to_s.strip.presence || "Refund requested by merchant"

    Refunds::Issue.call(
      merchant: current_user.merchant,
      redemption_transaction_id: redemption.id,
      actor: current_user,
      reason: reason,
      idempotency_key: nil
    )

    flash[:notice] = "Reembolso realizado correctamente."
    redirect_to merchant_gift_card_path(@gift_card)
  rescue ActiveRecord::RecordNotFound
    flash[:alert] = "Transacción no encontrada."
    redirect_to merchant_gift_card_path(@gift_card)
  rescue Refunds::Issue::ValidationError => e
    flash[:alert] = e.message
    redirect_to merchant_gift_card_path(@gift_card)
  end

  private

  def ensure_merchant
    unless current_user&.merchant?
      flash[:alert] = "You must be a merchant to access this area."
      redirect_to root_path
    end
  end

  def find_gift_card
    @gift_card = GiftCard.find(params[:gift_card_id])

    unless @gift_card.transactions.redemptions.where(merchant: current_user.merchant).exists?
      flash[:alert] = "You can only view gift cards redeemed at your store."
      redirect_to merchant_root_path
    end
  rescue ActiveRecord::RecordNotFound
    flash[:alert] = "Gift card not found."
    redirect_to merchant_root_path
  end
end


