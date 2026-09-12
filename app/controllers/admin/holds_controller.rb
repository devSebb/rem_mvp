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

    # Holds are per load (D5). Setting held_until to "now - 1 second" keeps
    # the audit trail ("this load WAS held") while the predicate flips to
    # false. Releases every held load on the card; the per-load release UI
    # arrives with the admin panel work (§9).
    released_ids = []
    @gift_card.with_lock do
      @gift_card.loads.currently_held.each do |load|
        load.update!(held_until: Time.current - 1.second, hold_released_by: current_user)
        released_ids << load.id
      end
    end

    Rails.logger.warn(
      "[HoldRelease] admin_user_id=#{current_user.id} gift_card_id=#{@gift_card.id} " \
      "loads=#{released_ids.inspect} reason=#{reason.inspect}"
    )

    flash[:notice] = "Bloqueo liberado para tarjeta ##{@gift_card.id}."
    redirect_back fallback_location: admin_holds_path
  end

  private


  def set_gift_card
    @gift_card = GiftCard.find(params[:id])
  end
end
