class Merchant::GiftCardsController < ApplicationController
  before_action :ensure_merchant
  before_action :find_gift_card

  def show
    # Get all redemption transactions for this gift card
    @transactions = @gift_card.transactions
                               .where(txn_type: :redemption)
                               .order(created_at: :desc)

    # Preload users who performed the redemptions
    actor_ids = @transactions.map { |t| t.metadata['actor_id'] }.compact.uniq
    @transaction_users = User.where(id: actor_ids).index_by(&:id)

    redemption_ids = @transactions.map(&:id).map(&:to_s)
    refunds = if redemption_ids.any?
      @gift_card.transactions
                .refunds
                .where("metadata->>'refund_of_transaction_id' IN (?)", redemption_ids)
    else
      Transaction.none
    end
    @refunds_by_redemption_id = refunds.index_by { |t| t.metadata["refund_of_transaction_id"].to_s }

    # Get the sender (spender) details
    @spender = @gift_card.sender

    # Get the recipient details
    @recipient = @gift_card.recipient
  end

  private

  def ensure_merchant
    unless current_user&.merchant?
      flash[:alert] = 'You must be a merchant to access this area.'
      redirect_to root_path
    end
  end

  def find_gift_card
    @gift_card = GiftCard.find(params[:id])

    # Ensure this gift card belongs to this merchant and has been redeemed
    unless @gift_card.merchant == current_user.merchant && @gift_card.transactions.where(txn_type: :redemption).exists?
      flash[:alert] = 'You can only view gift cards that belong to your store and have been redeemed.'
      redirect_to merchant_root_path
    end
  rescue ActiveRecord::RecordNotFound
    flash[:alert] = 'Gift card not found.'
    redirect_to merchant_root_path
  end
end
