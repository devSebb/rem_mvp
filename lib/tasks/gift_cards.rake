namespace :gift_cards do
  desc "Backfill encrypted raw codes for existing gift cards (generates new codes for cards without stored codes)"
  task backfill_raw_codes: :environment do
    puts "🔄 Backfilling raw codes for existing gift cards..."
    
    gift_cards = GiftCard.where(encrypted_raw_code: [nil, ''])
    count = gift_cards.count
    
    if count == 0
      puts "✅ All gift cards already have encrypted raw codes"
      next
    end
    
    puts "   Found #{count} gift cards without encrypted raw codes"
    
    gift_cards.find_each do |gift_card|
      # Generate a new code and store it encrypted
      new_code = CodeGenerator.generate
      gift_card.code_digest = BCrypt::Password.create(new_code)
      gift_card.raw_code = new_code
      gift_card.save!
      
      puts "   ✅ Updated gift card #{gift_card.id} with new code"
    end
    
    puts "✅ Backfill complete! Updated #{count} gift cards"
    puts "⚠️  Note: These gift cards now have NEW codes. Recipients will need to be notified of the new codes."
  end

  namespace :merchantless do
    desc "Report gift cards that have no merchant assigned"
    task report: :environment do
      scope = GiftCard.where(merchant_id: nil)
      count = scope.count

      puts "🔍 Found #{count} gift cards without a merchant"
      if count.positive?
        puts "   Showing up to 20 samples (id, remaining_balance_cents, status):"
        scope.limit(20).pluck(:id, :remaining_balance, :status).each do |id, balance, status|
          puts "   - ID #{id}: balance=#{balance}, status=#{status}"
        end
      end
    end

    desc "Cancel and expire gift cards that have no merchant assigned"
    task expire: :environment do
      scope = GiftCard.where(merchant_id: nil)
      count = scope.count

      puts "🚫 Found #{count} gift cards without a merchant"
      if count.zero?
        puts "✅ Nothing to do"
        next
      end

      now = Time.current
      updated = scope.update_all(
        status: GiftCard.statuses[:canceled],
        expires_at: now,
        updated_at: now
      )

      puts "✅ Marked #{updated} gift cards as canceled and expired"
    end
  end
end

