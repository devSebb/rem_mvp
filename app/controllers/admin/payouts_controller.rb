class Admin::PayoutsController < ApplicationController
  before_action :ensure_admin
  before_action :set_settlement, only: [:show, :mark_paid]

  # Per-merchant payout summary across the platform. The "pending" amount is
  # what we still owe each merchant — the gap between what they've redeemed
  # (revenue earned for them) and what we've already settled (paid out).
  def index
    @merchants = Merchant.includes(:settlements).order(:store_name)

    # Compute per-merchant totals with two grouped queries (no N+1).
    redeemed_by_merchant = Transaction
                             .where(txn_type: :redemption, status: :succeeded)
                             .group(:merchant_id)
                             .sum(:amount)

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
      # "Owed now" = total redeemed − already paid. Any pending settlements
      # are part of the redeemed-but-not-yet-paid balance.
      owed = redeemed - settled
      {
        merchant: merchant,
        redeemed: redeemed,
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
  end

  # Create a Settlement covering all unsettled redemptions for a merchant.
  # The period spans from the earliest unsettled redemption to now.
  def create
    merchant = Merchant.find(params[:merchant_id])

    unsettled_scope = unsettled_redemptions_for(merchant)
    if unsettled_scope.empty?
      redirect_to admin_payouts_path, alert: "No hay canjes sin liquidar para #{merchant.store_name}."
      return
    end

    period_start = unsettled_scope.minimum(:created_at).to_date
    period_end = Time.current.to_date
    amount = unsettled_scope.sum(:amount)

    settlement = merchant.settlements.create!(
      amount: amount,
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

  def ensure_admin
    return if current_user&.admin?
    flash[:alert] = "Acceso restringido."
    redirect_to root_path
  end

  def set_settlement
    @settlement = Settlement.find(params[:id])
  end

  # Redemption transactions for this merchant that haven't been included
  # in any settlement yet (succeeded redemptions outside of every existing
  # settlement period for this merchant).
  def unsettled_redemptions_for(merchant)
    base = Transaction.where(merchant: merchant, txn_type: :redemption, status: :succeeded)
    merchant.settlements.each do |s|
      base = base.where.not(created_at: s.period_start..s.period_end)
    end
    base
  end
end
