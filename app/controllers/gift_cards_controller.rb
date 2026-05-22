class GiftCardsController < ApplicationController
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
        render json: @gift_cards.as_json(include: [:sender, :recipient, :merchant])
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
end
