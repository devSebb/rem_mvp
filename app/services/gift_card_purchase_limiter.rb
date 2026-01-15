class GiftCardPurchaseLimiter
  MAX_PURCHASES_PER_24H = 5

  def self.can_purchase?(user:)
    return { allowed: false, count: 0, limit: MAX_PURCHASES_PER_24H, reason: "User is required" } unless user.present?

    # Count gift cards purchased by this user in the last 24 hours
    # Only count active, redeemed, or expired cards (not canceled)
    count = GiftCard.where(sender: user)
                    .where.not(status: :canceled)
                    .where('created_at >= ?', 24.hours.ago)
                    .count

    {
      allowed: count < MAX_PURCHASES_PER_24H,
      count: count,
      limit: MAX_PURCHASES_PER_24H,
      reason: count >= MAX_PURCHASES_PER_24H ? "Maximum of #{MAX_PURCHASES_PER_24H} gift cards per 24 hours reached" : nil
    }
  end

  def self.purchases_in_last_24h(user:)
    return 0 unless user.present?

    GiftCard.where(sender: user)
            .where.not(status: :canceled)
            .where('created_at >= ?', 24.hours.ago)
            .count
  end
end

