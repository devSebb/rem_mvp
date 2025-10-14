class QrTokenService
  TOKEN_EXPIRY_MINUTES = 5

  def self.generate_token(gift_card_id)
    timestamp = Time.current.to_i
    signature = sign("#{gift_card_id}:#{timestamp}")
    "#{gift_card_id}:#{timestamp}:#{signature}"
  end

  def self.verify_token(token)
    return nil if token.blank?

    gift_card_id, timestamp, signature = token.split(':')
    return nil unless gift_card_id && timestamp && signature

    # Check expiration (5 minutes)
    token_time = Time.at(timestamp.to_i)
    return nil if token_time < TOKEN_EXPIRY_MINUTES.minutes.ago

    # Verify signature
    expected = sign("#{gift_card_id}:#{timestamp}")
    return nil unless ActiveSupport::SecurityUtils.secure_compare(signature, expected)

    # Find and return the gift card
    GiftCard.find_by(id: gift_card_id)
  end

  def self.token_expired?(token)
    return true if token.blank?

    gift_card_id, timestamp, signature = token.split(':')
    return true unless timestamp

    token_time = Time.at(timestamp.to_i)
    token_time < TOKEN_EXPIRY_MINUTES.minutes.ago
  end

  def self.extract_gift_card_id(token)
    return nil if token.blank?

    gift_card_id, timestamp, signature = token.split(':')
    gift_card_id
  end

  private

  def self.sign(data)
    OpenSSL::HMAC.hexdigest('SHA256', Rails.application.secret_key_base, data)
  end
end
