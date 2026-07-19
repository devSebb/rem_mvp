# Command center: every figure on this page is derived from the ledger and
# live tables (no cached/derived columns), so what admin sees is what the
# database actually says.
class Admin::DashboardController < Admin::BaseController
  def index
    @settings = PlatformSetting.current
    week_ago = 7.days.ago
    today = Time.current.beginning_of_day

    consumers = User.where(role: :user)
    @users = {
      total: consumers.active.count,
      claimed: consumers.active.where.not(claimed_at: nil).count,
      pending: consumers.active.where(claimed_at: nil).count,
      new_this_week: consumers.active.where(claimed_at: week_ago..).count,
      deleted: consumers.where.not(deleted_at: nil).count
    }

    @cards = {
      total: GiftCard.count,
      active: GiftCard.active.count,
      redeemed: GiftCard.redeemed.count,
      held: GiftCard.currently_held.count,
      disputed: GiftCard.disputed.count,
      issued_volume_cents: GiftCard.sum(:amount),
      liability_cents: GiftCard.active.sum(:remaining_balance)
    }

    purchases = Transaction.where(txn_type: :purchase, status: :succeeded)
    redemptions = Transaction.where(txn_type: :redemption, status: :succeeded)
    @activity = {
      purchases_today: purchases.where(created_at: today..).count,
      purchases_7d_count: purchases.where(created_at: week_ago..).count,
      purchases_7d_cents: purchases.where(created_at: week_ago..).sum(:amount),
      redemptions_today: redemptions.where(created_at: today..).count,
      redemptions_7d_count: redemptions.where(created_at: week_ago..).count,
      redemptions_7d_cents: redemptions.where(created_at: week_ago..).sum(:amount),
      failed_redemptions_7d: Transaction.where(txn_type: :redemption, status: :failed, created_at: week_ago..).count
    }

    # Fee revenue vs. Stripe processing cost, both read from the purchase
    # ledger rows (fee_cents / stripe_fee_cents metadata written at fulfillment).
    @economics = {
      fees_collected_cents: purchases.sum(Arel.sql("COALESCE((metadata->>'fee_cents')::bigint, 0)")).to_i,
      stripe_costs_cents: purchases.sum(Arel.sql("COALESCE((metadata->>'stripe_fee_cents')::bigint, 0)")).to_i
    }

    redeemed_total = redemptions.sum(:amount)
    commission = @settings.merchant_commission_cents_for(redeemed_total)
    @payouts = {
      owed_cents: (redeemed_total - commission) - Settlement.paid.sum(:amount),
      pending_settlements: Settlement.pending.count
    }

    @merchants = {
      total: Merchant.count,
      active: Merchant.active.count,
      suspended: Merchant.suspended.count
    }

    # Incident states that need an admin's eyes: declined purchases that
    # never recovered, and refunds Stripe reported as failed (buyer did NOT
    # get their money back).
    @incidents = {
      unresolved_declines: PaymentFailure.unresolved.count,
      declines_7d: PaymentFailure.where(last_failed_at: week_ago..).count,
      failed_refunds: Transaction.refunds.where(status: :failed).count
    }

    @recent_gift_cards = GiftCard.includes(:recipient).order(created_at: :desc).limit(5)
    @recent_transactions = Transaction.includes(:merchant, gift_card: :sender).order(created_at: :desc).limit(8)
    @latest_merchants = Merchant.order(created_at: :desc).limit(5)
    @redeemed_by_merchant = redemptions.group(:merchant_id).sum(:amount)

    @sidekiq = sidekiq_stats
  end

  private

  # Queue health snapshot; nil when Redis is unreachable (shown as "N/D").
  def sidekiq_stats
    stats = Sidekiq::Stats.new
    { enqueued: stats.enqueued, retries: stats.retry_size, dead: stats.dead_size }
  rescue StandardError
    nil
  end
end
