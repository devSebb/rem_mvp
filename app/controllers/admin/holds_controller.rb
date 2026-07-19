class Admin::HoldsController < Admin::BaseController
  before_action :set_gift_card, only: [:release]

  # Currently-held cards, ordered by hold expiration so the soonest-to-unlock
  # show first. Admin can review and decide to release early if they've
  # verified the buyer through some out-of-band channel.
  def index
    authorize GiftCard, :index_holds?

    @held_gift_cards = GiftCard
                         .currently_held
                         .includes(:sender, :recipient, :merchant)
                         .order(held_until: :asc)
  end

  # Release a hold early. Requires a typed reason — required for audit
  # since this overrides our fraud detection.
  def release
    authorize @gift_card, :release_hold?

    reason = params[:reason].to_s.strip
    if reason.blank?
      flash[:alert] = "Debes proporcionar una razón para liberar el bloqueo."
      redirect_back fallback_location: admin_holds_path and return
    end

    unless @gift_card.held?
      flash[:alert] = "Esta tarjeta no está bajo bloqueo de seguridad."
      redirect_back fallback_location: admin_holds_path and return
    end

    # Setting held_until to "now - 1 second" is cleaner than nulling it —
    # the column still tells us "this card WAS held" for audit, but the
    # predicate (held_until > Time.current) flips to false.
    @gift_card.update!(held_until: Time.current - 1.second)

    Rails.logger.warn(
      "[HoldRelease] admin_user_id=#{current_user.id} gift_card_id=#{@gift_card.id} " \
      "reason=#{reason.inspect} risk_score=#{@gift_card.risk_score}"
    )

    flash[:notice] = "Bloqueo liberado para tarjeta ##{@gift_card.id}."
    redirect_back fallback_location: admin_holds_path
  end

  private


  def set_gift_card
    @gift_card = GiftCard.find(params[:id])
  end
end
