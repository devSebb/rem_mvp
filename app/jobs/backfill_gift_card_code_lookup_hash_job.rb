require "digest"

class BackfillGiftCardCodeLookupHashJob < ApplicationJob
  queue_as :default

  def perform(start_after_id: nil, batch_size: 500)
    scope = GiftCard.where(code_lookup_hash: nil).where.not(encrypted_raw_code: [nil, ""])
    scope = scope.where("id > ?", start_after_id) if start_after_id.present?

    batch = scope.order(:id).limit(batch_size).to_a
    return if batch.empty?

    processed = 0
    skipped = 0
    last_id = batch.last.id

    batch.each do |gift_card|
      raw_code = decrypt_raw_code_without_regenerating(gift_card)
      if raw_code.blank?
        skipped += 1
        next
      end

      normalized = GiftCard.normalize_code_for_lookup(raw_code)
      lookup_hash = Digest::SHA256.hexdigest(normalized)
      gift_card.update_column(:code_lookup_hash, lookup_hash)
      processed += 1
    rescue => e
      skipped += 1
      Rails.logger.warn("[BackfillCodeLookupHash] gift_card_id=#{gift_card.id} skipped error=#{e.class}: #{e.message}")
    end

    Rails.logger.info(
      "[BackfillCodeLookupHash] processed=#{processed} skipped=#{skipped} " \
      "batch_size=#{batch.size} start_after_id=#{start_after_id || 0} last_id=#{last_id}"
    )

    # Continue asynchronously until no records remain in scope.
    self.class.perform_later(start_after_id: last_id, batch_size: batch_size) if batch.size == batch_size
  end

  private

  # Mirrors GiftCard decryption logic but never regenerates codes.
  def decrypt_raw_code_without_regenerating(gift_card)
    encrypted = gift_card.encrypted_raw_code
    return nil if encrypted.blank?

    key = Rails.application.credentials.secret_key_base || Rails.application.secret_key_base
    encryptor = ActiveSupport::MessageEncryptor.new(key[0..31])
    encryptor.decrypt_and_verify(encrypted)
  rescue
    nil
  end
end
