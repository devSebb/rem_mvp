class GiftCardsController < ApplicationController
  include ConsumerWebGate

  before_action :set_gift_card, only: [:show]

  # Web wallet view. Web purchase flow has been removed — purchases are done
  # exclusively through the mobile app. This view is read-only.
  def index
    @gift_cards = policy_scope(GiftCard).includes(:sender, :recipient, :merchant).order(created_at: :desc)
    # Track owner activity once on HTML wallet load to avoid duplicate writes
    # when the page immediately requests JSON data.
    if request.format.html? && current_user.present?
      gift_card_ids = @gift_cards.pluck(:id)
      GiftCard.where(id: gift_card_ids).update_all(last_owner_activity_at: Time.current) if gift_card_ids.any?
    end

    respond_to do |format|
      format.html
      format.json do
        render json: @gift_cards.map { |card| serialize_wallet_card(card) }
      end
    end
  end

  def show
    authorize @gift_card
    # Track owner activity for balance check (only if current_user is owner)
    @gift_card.touch_owner_activity! if current_user.present? && (current_user == @gift_card.sender || current_user == @gift_card.recipient)
  end

  private

  def set_gift_card
    @gift_card = GiftCard.find(params[:id])
  end

  # Explicit whitelist for the wallet JSON. The counterparty on a card is
  # another person's User row — never serialize full records here (they
  # carry national_id, date_of_birth, address, phone; merchants carry
  # secret digests). Only fields the wallet view actually renders.
  def serialize_wallet_card(card)
    {
      id: card.id,
      amount: card.amount,
      remaining_balance: card.remaining_balance,
      currency: card.currency,
      status: card.status,
      created_at: card.created_at,
      redeemed_at: card.redeemed_at,
      sender_id: card.sender_id,
      recipient_id: card.recipient_id,
      sender: serialize_wallet_party(card.sender),
      recipient: serialize_wallet_party(card.recipient),
      merchant: card.merchant ? { id: card.merchant.id, store_name: card.merchant.store_name } : nil
    }
  end

  def serialize_wallet_party(user)
    return nil unless user

    { id: user.id, name: user.name }
  end
end
