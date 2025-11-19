class RedemptionIdempotencyService
  # In-memory fallback if Redis is not available
  @@memory_store = {}
  @@memory_store_mutex = Mutex.new

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
    
    begin
      Rails.cache.write(key, data, expires_in: 5.minutes)
    rescue => e
      # Fallback to in-memory store if Redis is not available
      Rails.logger.warn "⚠️ Redis not available, using in-memory store for idempotency: #{e.message}"
      @@memory_store_mutex.synchronize do
        @@memory_store[key] = { data: data, expires_at: 5.minutes.from_now.to_i }
      end
    end
    
    token
  end

  def self.consume_token(token)
    key = "redemption:#{token}"
    
    begin
      data = Rails.cache.read(key)
      if data
        Rails.cache.delete(key)
        return data
      end
    rescue => e
      Rails.logger.warn "⚠️ Redis not available, checking in-memory store: #{e.message}"
    end
    
    # Fallback to in-memory store
    @@memory_store_mutex.synchronize do
      stored = @@memory_store[key]
      if stored && stored[:expires_at] > Time.current.to_i
        @@memory_store.delete(key)
        return stored[:data]
      elsif stored
        # Expired, clean it up
        @@memory_store.delete(key)
      end
    end
    
    nil
  end

  def self.token_exists?(token)
    key = "redemption:#{token}"
    
    begin
      return Rails.cache.exist?(key)
    rescue => e
      Rails.logger.warn "⚠️ Redis not available, checking fallback stores: #{e.message}"
    end
    
    # Fallback 1: Check in-memory store (only works within same process)
    @@memory_store_mutex.synchronize do
      stored = @@memory_store[key]
      if stored
        if stored[:expires_at] > Time.current.to_i
          Rails.logger.debug "✅ Token found in in-memory store"
          return true
        else
          # Expired, clean it up
          @@memory_store.delete(key)
        end
      end
    end
    
    # Fallback 2: In development, if token format is valid, accept it
    # This allows redemption to work even without Redis/session
    if Rails.env.development?
      if token.present? && token.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
        Rails.logger.info "✅ Development mode: accepting valid token format"
        return true
      end
    end
    
    false
  end
end
