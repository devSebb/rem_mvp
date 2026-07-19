class Admin::PayoutsController < Admin::BaseController
  before_action :set_settlement, only: [:show, :mark_paid]

  # Per-merchant payout summary across the platform. The "pending" amount is
  # what we still owe each merchant — the gap between what they've redeemed
  # (revenue earned for them) and what we've already settled (paid out).
  def index
    @merchants = Merchant.includes(:settlements).order(:store_name)
    @settings = PlatformSetting.current

    # Per-merchant totals with grouped queries (no N+1). "Redeemed" is net
    # of merchant reversals — a reversed redemption returns value to the
    # card, so the merchant is never paid for it.
    redeemed_by_merchant = Transaction.net_redeemed_cents_by_merchant

    settled_by_merchant = Settlement
                            .where(payout_status: :paid)
                            .group(:merchant_id)
                            .sum(:amount)

    pending_settlement_total_by_merchant = Settlement
                                              .where(payout_status: :pending)
                                              .group(:merchant_id)
                                              .sum(:amount)

    @rows = @merchants.map do |merchant|
      redeemed = redeemed_by_merchant[merchant.id].to_i
      settled = settled_by_merchant[merchant.id].to_i
      pending_in_settlements = pending_settlement_total_by_merchant[merchant.id].to_i
      # Platform commission is withheld from settlements (0 at launch).
      # Settlement.amount is stored NET of commission, so owed/settled/
      # pending all compare net-to-net.
      commission = @settings.merchant_commission_cents_for(redeemed)
      net_redeemed = redeemed - commission
      # "Owed now" = net redeemed − already paid. Any pending settlements
      # are part of the redeemed-but-not-yet-paid balance.
      owed = net_redeemed - settled
      {
        merchant: merchant,
        redeemed: redeemed,
        commission: commission,
        settled: settled,
        owed: owed,
        pending_in_settlements: pending_in_settlements,
        # "Unsettled" = redemptions not yet attached to any settlement record.
        # Click "Crear pago" on a merchant with unsettled > 0 to create one.
        unsettled: owed - pending_in_settlements
      }
    end

    @total_owed = @rows.sum { |r| r[:owed] }
    @total_pending_settlements = @rows.sum { |r| r[:pending_in_settlements] }

    @recent_settlements = Settlement.includes(:merchant).order(created_at: :desc).limit(20)
  end

  def show
    @merchant = @settlement.merchant
    @transactions = @settlement.transactions.includes(gift_card: [:sender, :recipient])
                              .order(created_at: :desc)
    @reversals = @settlement.reversals.includes(gift_card: [:sender, :recipient])
                            .order(created_at: :desc)
  end

  # Create a Settlement covering all unsettled redemptions for a merchant.
  # The period spans from the earliest unsettled redemption to now.
  def create
    merchant = Merchant.find(params[:merchant_id])

    unsettled_redemptions = merchant.unsettled_redemptions
    unsettled_reversals = merchant.unsettled_reversals
    if unsettled_redemptions.empty? && unsettled_reversals.empty?
      redirect_to admin_payouts_path, alert: "No hay canjes sin liquidar para #{merchant.store_name}."
      return
    end

    # gross = what the merchant actually earned this window: redemptions
    # minus reversals. Negative or zero means reversals outpaced new
    # redemptions — the merchant owes value back; block instead of writing
    # a nonsensical settlement (future redemptions will absorb it).
    gross = unsettled_redemptions.sum(:amount) - unsettled_reversals.sum(:amount)
    if gross <= 0
      redirect_to admin_payouts_path,
                  alert: "Las reversas superan los canjes sin liquidar de #{merchant.store_name} " \
                         "(neto #{format('%.2f', gross / 100.0)} USD). Se compensará con futuros canjes."
      return
    end

    period_start = [unsettled_redemptions.minimum(:created_at), unsettled_reversals.minimum(:created_at)].compact.min.to_date
    period_end = Time.current.to_date

    # amount = what we actually pay the merchant (gross minus platform
    # commission). The gross and rate are stored so the payout stays
    # explainable even if the commission changes later.
    settings = PlatformSetting.current
    commission = settings.merchant_commission_cents_for(gross)

    settlement = merchant.settlements.create!(
      amount: gross - commission,
      gross_amount: gross,
      commission_amount: commission,
      commission_bps: settings.merchant_commission_bps,
      period_start: period_start,
      period_end: period_end,
      payout_status: :pending
    )

    redirect_to admin_payout_path(settlement), notice: "Liquidación creada para #{merchant.store_name}."
  end

  def mark_paid
    if @settlement.paid?
      redirect_to admin_payout_path(@settlement), alert: "Esta liquidación ya está marcada como pagada."
      return
    end

    @settlement.update!(
      payout_status: :paid,
      paid_at: Time.current,
      paid_by_admin: current_user,
      payment_method: params[:payment_method].to_s.strip.presence,
      payment_reference: params[:payment_reference].to_s.strip.presence
    )

    redirect_to admin_payout_path(@settlement), notice: "Liquidación marcada como pagada."
  end

  private


  def set_settlement
    @settlement = Settlement.find(params[:id])
  end

  # Unsettled-window logic lives on Merchant (unsettled_redemptions /
  # unsettled_reversals / unsettled_net_redeemed_cents), shared with the
  # merchant dashboard so both sides always agree on "pendiente".
end
