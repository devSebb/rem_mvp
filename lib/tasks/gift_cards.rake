# Classifies a gift card by how it was funded, using the LIVE Stripe key that the
# running process is configured with. Returns one of:
#   :no_stripe   - payment_intent_id is blank (manual/seed/test card, never charged)
#   :test        - has a payment_intent_id, but Stripe (live) reports it test-mode / missing => FAKE money
#   :live        - has a payment_intent_id that resolves live-mode in Stripe   => REAL money
#   :unknown     - a Stripe/network error we could not resolve (NEVER auto-cancel these)
def classify_gift_card_funding(gift_card)
  pi_id = gift_card.payment_intent_id
  return [:no_stripe, nil] if pi_id.blank?

  begin
    pi = Stripe::PaymentIntent.retrieve(pi_id)
    pi.livemode ? [:live, pi_id] : [:test, pi_id]
  rescue Stripe::InvalidRequestError => e
    # A test-mode payment_intent does not exist under the live key => resource_missing.
    e.respond_to?(:code) && e.code == "resource_missing" ? [:test, pi_id] : [:unknown, pi_id]
  rescue Stripe::StripeError
    [:unknown, pi_id]
  end
end

namespace :gift_cards do
  desc "READ-ONLY audit: classify every gift card as real-money (live) vs fake (test/no-stripe) by asking Stripe"
  task audit_funding: :environment do
    require "csv"

    total = GiftCard.count
    puts "🔍 Auditing #{total} gift cards against Stripe (live key)..."
    puts "   This makes one Stripe API call per Stripe-funded card. No data is modified.\n\n"

    buckets = Hash.new { |h, k| h[k] = [] }
    csv_path = Rails.root.join("tmp", "gift_card_funding_audit.csv")

    CSV.open(csv_path, "w") do |csv|
      csv << %w[id bucket status amount_cents remaining_balance_cents payment_intent_id
                sender_email recipient_email merchant created_at]

      GiftCard.includes(:sender, :recipient, :merchant).find_each do |gc|
        bucket, pi_id = classify_gift_card_funding(gc)
        buckets[bucket] << gc.id

        row = [
          gc.id, bucket, gc.status, gc.amount, gc.remaining_balance, pi_id,
          gc.sender&.email, gc.recipient&.email, gc.merchant&.store_name,
          gc.created_at&.iso8601
        ]
        csv << row
        puts format("  #%-6s %-9s %-8s $%-7s bal:$%-7s to:%-28s %s",
                    gc.id, bucket, gc.status,
                    (gc.amount.to_i / 100.0), (gc.remaining_balance.to_i / 100.0),
                    (gc.recipient&.email || "-").to_s[0, 28], pi_id || "(no stripe)")
      end
    end

    puts "\n📊 Summary"
    puts "   💰 LIVE (real money, KEEP):      #{buckets[:live].size}  ids=#{buckets[:live].sort.inspect}"
    puts "   🧪 TEST (fake, safe to cancel):  #{buckets[:test].size}"
    puts "   🚫 NO-STRIPE (fake, cancel):     #{buckets[:no_stripe].size}"
    puts "   ⚠️  UNKNOWN (review manually):    #{buckets[:unknown].size}  ids=#{buckets[:unknown].sort.inspect}"
    puts "\n   Full detail written to: #{csv_path}"
    puts "   👉 Cross-check the LIVE ids above against your own list of real cards before cancelling anything."
  end

  desc "Cancel FAKE gift cards (test + no-stripe). DRY-RUN by default. Set CONFIRM=yes to write; PROTECT_IDS=1,2 to force-keep."
  task cancel_fakes: :environment do
    dry_run    = ENV["CONFIRM"].to_s.downcase != "yes"
    protect_ids = ENV["PROTECT_IDS"].to_s.split(/[,\s]+/).reject(&:blank?).map(&:to_i).to_set

    puts(dry_run ? "🧪 DRY-RUN (no changes). Re-run with CONFIRM=yes to apply." : "⚠️  LIVE RUN — cards WILL be canceled.")
    puts "   Protected (never touched) ids: #{protect_ids.to_a.sort.inspect}" if protect_ids.any?
    puts ""

    to_cancel = []
    skipped_live = []
    skipped_unknown = []

    GiftCard.where.not(status: :canceled).find_each do |gc|
      next if protect_ids.include?(gc.id) # belt-and-suspenders: never cancel a protected id

      bucket, _pi = classify_gift_card_funding(gc)
      case bucket
      when :live    then skipped_live << gc.id
      when :unknown then skipped_unknown << gc.id
      when :test, :no_stripe then to_cancel << gc
      end
    end

    puts "   Would cancel #{to_cancel.size} fake card(s): #{to_cancel.map(&:id).sort.inspect}"
    puts "   Keeping #{skipped_live.size} LIVE card(s): #{skipped_live.sort.inspect}"
    puts "   Skipping #{skipped_unknown.size} UNKNOWN card(s) (verify by hand): #{skipped_unknown.sort.inspect}" if skipped_unknown.any?

    if dry_run
      puts "\n🧪 DRY-RUN complete. Nothing changed."
      next
    end

    now = Time.current
    canceled = 0
    to_cancel.each do |gc|
      gc.update_columns(status: GiftCard.statuses[:canceled], remaining_balance: 0, updated_at: now)
      canceled += 1
    end
    puts "\n✅ Canceled and zeroed #{canceled} fake gift card(s). LIVE cards were left untouched."
  end

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

  desc "Backfill code_lookup_hash for existing gift cards without changing codes"
  task backfill_code_lookup_hash: :environment do
    pending = GiftCard.where(code_lookup_hash: nil).count
    puts "🔄 Enqueuing code_lookup_hash backfill for #{pending} gift cards..."
    BackfillGiftCardCodeLookupHashJob.perform_later
    puts "✅ Backfill job enqueued"
  end

  desc "Report code_lookup_hash coverage"
  task report_code_lookup_hash_coverage: :environment do
    total = GiftCard.count
    with_hash = GiftCard.where.not(code_lookup_hash: nil).count
    without_hash = total - with_hash
    pct = total.zero? ? 100.0 : ((with_hash.to_f / total.to_f) * 100).round(2)

    puts "📊 GiftCard code lookup coverage"
    puts "   Total: #{total}"
    puts "   With code_lookup_hash: #{with_hash}"
    puts "   Without code_lookup_hash: #{without_hash}"
    puts "   Coverage: #{pct}%"
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

    desc "Cancel gift cards that have no merchant assigned (expiration removed - gift cards never expire)"
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
        updated_at: now
      )

      puts "✅ Marked #{updated} gift cards as canceled (expiration removed - gift cards never expire)"
    end
  end
end

