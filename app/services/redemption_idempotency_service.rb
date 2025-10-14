class RedemptionIdempotencyService
  def self.generate_token
    SecureRandom.uuid
  end

  def self.store_token(token, gift_card_id, redemption_amount, merchant_id)
    key = "redemption:#{token}"
    data = {
      gift_card_id: gift_card_id,
      redemption_amount: redemption_amount,
      merchant_id: merchant_id,
      created_at: Time.current.to_i
    }
    
    Rails.cache.write(key, data, expires_in: 5.minutes)
    token
  end

  def self.consume_token(token)
    key = "redemption:#{token}"
    data = Rails.cache.read(key)
    
    return nil unless data
    
    # Mark as consumed by deleting the token
    Rails.cache.delete(key)
    
    data
  end

  def self.token_exists?(token)
    key = "redemption:#{token}"
    Rails.cache.exist?(key)
  end
end
