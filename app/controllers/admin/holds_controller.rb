class Admin::HoldsController < Admin::BaseController
  before_action :set_load, only: [:release]

  # Currently-held LOADS (§9), soonest-to-unlock first. Admin can review and
  # release early after verifying the buyer through some out-of-band channel.
  def index
    authorize GiftCard, :index_holds?

    @held_loads = GiftCardLoad.in_scope
                              .currently_held
                              .includes(:sender, gift_card: [:recipient, :merchant])
                              .order(held_until: :asc)
  end

  # Release ONE load's hold early. Requires a typed reason — required for
  # audit since this overrides our fraud detection. The rest of the card is
  # untouched (D5).
  def release
    authorize @load, :release_hold?

    reason = params[:reason].to_s.strip
    if reason.blank?
      flash[:alert] = "Debes proporcionar una razón para liberar el bloqueo."
      redirect_back fallback_location: admin_holds_path and return
    end

    unless @load.held?
      flash[:alert] = "Esta recarga no está bajo bloqueo de seguridad."
      redirect_back fallback_location: admin_holds_path and return
    end

    card = @load.gift_card
    card.with_lock do
      @load.reload
      # "now - 1 second" keeps the audit trail ("this load WAS held") while
      # the predicate flips to false.
      @load.update!(held_until: Time.current - 1.second, hold_released_by: current_user)
    end
    Messaging::LoadEventPusher.hold_released(@load)

    Rails.logger.warn(
      "[HoldRelease] admin_user_id=#{current_user.id} gift_card_id=#{card.id} load_id=#{@load.id} reason=#{reason.inspect}"
    )

    flash[:notice] = "Retención liberada: recarga ##{@load.id} de la tarjeta ##{card.id}."
    redirect_back fallback_location: admin_holds_path
  end

  private

  def set_load
    @load = GiftCardLoad.find(params[:id])
  end
end
