# Development seeds for the reloadable-card model (RELOADABLE_CARD_PLAN.md
# §10 Phase 2 step 6). Idempotent: every record is keyed on a stable marker
# and re-running only fills gaps. Runs on the Phase 1 schema (before the
# Phase 2 migration) and on the Phase 2 schema alike.
#
# NOT for production: Render never runs db:seed, and the users below have a
# fixed password.
#
# What it creates:
#   * admin / merchant / regular / sender users
#   * the seven launch merchants from production (§5.6) so the Farmaenlace
#     redemption group can be seeded exactly as the Phase 2 migration does,
#     plus the two demo stores
#   * ONE reloadable card for user@example.com at Demo Store with THREE loads
#     (a gift from the admin, a gift from sender@example.com, a self-reload),
#     partially redeemed FIFO across the first two loads
#   * a duplicate (recipient, merchant) pair at Sunset Pharmacy while the
#     Phase 2 unique index does not exist yet, so `DRY_RUN=1 rake
#     gift_cards:merge_duplicates` has something to list (§16.4-B); once the
#     index exists the same money is seeded as one card with two loads

puts "🌱 Seeding database..."

# ── helpers ────────────────────────────────────────────────────────────

def rotate_and_log_api_key!(merchant)
  return unless Rails.env.development?

  creds = Merchant.generate_keys!(merchant)
  message = "🔐 Merchant API secret for #{merchant.name} (public key: #{creds[:public_key]}): #{creds[:secret_key]}"
  Rails.logger.info(message)
  puts message
end

def seed_user!(email:, name:, role: :user, phone: nil, national_id: nil)
  User.find_or_create_by!(email: email) do |user|
    user.name = name
    user.password = "password123"
    user.password_confirmation = "password123"
    user.role = role
    user.phone = phone
    user.national_id = national_id
  end
end

def seed_merchant!(user:, store_name:, address:, contact_email:, iban: nil, partner_redemption: false)
  merchant = Merchant.find_or_initialize_by(user: user)
  merchant.store_name = store_name
  merchant.name = store_name
  merchant.address = address
  merchant.contact_email = contact_email
  merchant.bank_account_iban = iban if iban
  merchant.partner_redemption = partner_redemption
  merchant.save!
  merchant
end

def pair_index_exists?
  ActiveRecord::Base.connection.index_exists?(:gift_cards, [:recipient_id, :merchant_id],
                                              name: "index_gift_cards_on_recipient_merchant_unique")
end

# One card per (recipient, merchant), keyed on a checkout_session marker so
# re-runs find it. The marker also suppresses the legacy after_create
# issuance transaction — loads below write their own ledger rows.
def seed_card!(marker:, recipient:, merchant:, first_sender:, first_amount_cents:)
  if (existing = GiftCard.find_by(checkout_session_id: marker))
    # After the Phase 2 merge the seeded card may be an absorbed shell whose
    # money now lives on the pair's survivor — keep seeding onto that.
    existing = existing.merged_into while existing.merged_into_id.present?
    return existing
  end

  begin
    card = GiftCard.new(
      sender: first_sender, recipient: recipient, merchant: merchant,
      amount: first_amount_cents, currency: "USD", checkout_session_id: marker
    )
    card.generate_code!
    # set_defaults mirrored amount into remaining_balance/total_loaded_cents;
    # start empty — seed_load! adds the money load by load.
    card.update_columns(remaining_balance: 0, total_loaded_cents: 0, amount: 0)
    card
  end
end

# A load plus its issuance ledger row, credited onto the card (§3.2, §6.7).
def seed_load!(card, marker:, sender:, amount_cents:, note: nil, source: :issuance, held: false)
  existing = GiftCardLoad.find_by(checkout_session_id: marker)
  return existing if existing

  card.with_lock do
    card.reload
    load = card.loads.create!(
      sender: sender, source: source, checkout_session_id: marker,
      amount_cents: amount_cents, remaining_cents: amount_cents, currency: card.currency, note: note,
      held_until: (held ? 24.hours.from_now : nil), risk_score: (held ? 70 : nil), risk_level: (held ? "elevated" : nil)
    )
    Transaction.create!(
      gift_card: card, gift_card_load: load, merchant: card.merchant, user: sender,
      amount: amount_cents, currency: card.currency, txn_type: :issuance, status: :succeeded,
      processor_ref: "issuance_#{marker}", metadata: { source: "seed" }
    )
    GiftCard.where(id: card.id).update_all([
      "remaining_balance = remaining_balance + ?, total_loaded_cents = total_loaded_cents + ?, amount = amount + ?, last_loaded_at = ?",
      amount_cents, amount_cents, amount_cents, load.created_at
    ])
    load
  end
end

# A merchant redemption drawn FIFO from the card's spendable loads, with one
# allocation per load it touched (§3.3, §5.4). Mini version of Phase 3's
# Loads::Allocator, enough for demo data.
def seed_redemption!(card, marker:, redeemer:, actor:, amount_cents:)
  return if Transaction.exists?(processor_ref: "seed_redemption_#{marker}")

  card.with_lock do
    card.reload
    loads = card.loads.spendable.fifo.to_a
    raise "seed: card #{card.id} has only #{loads.sum(&:remaining_cents)} spendable, cannot redeem #{amount_cents}" if loads.sum(&:remaining_cents) < amount_cents

    txn = Transaction.create!(
      gift_card: card, merchant: redeemer, user: actor, amount: amount_cents, currency: card.currency,
      txn_type: :redemption, status: :succeeded, processor_ref: "seed_redemption_#{marker}",
      metadata: { source: "seed", redeemed_at: Time.current.iso8601 }
    )
    left = amount_cents
    loads.each do |load|
      break if left.zero?

      take = [left, load.remaining_cents].min
      RedemptionAllocation.create!(ledger_transaction: txn, gift_card_load: load, amount_cents: take, direction: :debit)
      GiftCardLoad.where(id: load.id).update_all(["remaining_cents = remaining_cents - ?", take])
      load.reload.sync_status!
      left -= take
    end
    GiftCard.where(id: card.id).update_all(["remaining_balance = remaining_balance - ?", amount_cents])
    card.touch_owner_activity!
    txn
  end
end

# ── users ──────────────────────────────────────────────────────────────

admin = seed_user!(email: "admin@example.com", name: "Admin User", role: :admin, national_id: "ADMIN001")
merchant_user = seed_user!(email: "merchant@example.com", name: "Merchant Owner", role: :merchant, phone: "+1234567890", national_id: "MERC001A")
merchant_user_two = seed_user!(email: "merchant2@example.com", name: "Second Merchant Owner", role: :merchant, phone: "+1098765432", national_id: "MERC002B")
regular_user = seed_user!(email: "user@example.com", name: "Regular User", phone: "+1987654321", national_id: "USER001C")
sender_user = seed_user!(email: "sender@example.com", name: "Sender Abroad", phone: "+1555000100", national_id: "SEND001D")
puts "✅ Users: #{[admin, merchant_user, merchant_user_two, regular_user, sender_user].map(&:email).join(', ')}"

# ── merchants ──────────────────────────────────────────────────────────

merchant = seed_merchant!(user: merchant_user, store_name: "Demo Store", address: "123 Main Street, City, State 12345",
                          contact_email: "merchant@example.com", iban: "US12345678901234567890")
rotate_and_log_api_key!(merchant)
merchant_two = seed_merchant!(user: merchant_user_two, store_name: "Sunset Pharmacy", address: "456 Coastal Road, Beach City",
                              contact_email: "merchant2@example.com", iban: "US98765432109876543210")
rotate_and_log_api_key!(merchant_two)
puts "✅ Demo merchants: #{merchant.store_name}, #{merchant_two.store_name}"

# The seven production launch merchants (§5.6), by store_name — the same
# names RedemptionGroups::SeedFarmaenlace resolves in the Phase 2 migration.
RedemptionGroups::SeedFarmaenlace::MEMBERS.each do |prod_id, store_name|
  next if Merchant.exists?(store_name: store_name)

  slug = store_name.parameterize
  owner = seed_user!(email: "#{slug}@example.com", name: "#{store_name} Owner", role: :merchant,
                     phone: "+1555000#{format('%03d', 200 + prod_id)}", national_id: "MERCH#{format('%03d', prod_id)}")
  seed_merchant!(user: owner, store_name: store_name, address: "Quito, Ecuador", contact_email: "#{slug}@example.com",
                 partner_redemption: store_name != "Farmacias Económicas") # matches prod flags (§5.6)
end
puts "✅ Launch merchants present: #{RedemptionGroups::SeedFarmaenlace::MEMBERS.map(&:last).join(', ')}"

# Farmaenlace group (D6). The seven launch merchants get it exactly as the
# migration assigns them; in development every other pre-existing merchant
# joins too, mirroring production where every merchant that exists at
# Phase 2 time is in the group. Merchants created later get no group.
group_result = RedemptionGroups::SeedFarmaenlace.call
farmaenlace = group_result[:group]
Merchant.where(redemption_group_id: nil).update_all(redemption_group_id: farmaenlace.id) if Rails.env.development?
puts "✅ Redemption group '#{farmaenlace.name}': #{farmaenlace.merchants.count} merchants"

# ── the reloadable demo card: one card, three loads ────────────────────

card = seed_card!(marker: "cs_seed_main", recipient: regular_user, merchant: merchant,
                  first_sender: admin, first_amount_cents: 5000)
seed_load!(card, marker: "cs_seed_main_load_1", sender: admin, amount_cents: 5000, note: "¡Feliz cumpleaños!")
seed_load!(card, marker: "cs_seed_main_load_2", sender: sender_user, amount_cents: 3000, note: "Para la farmacia")
seed_load!(card, marker: "cs_seed_main_load_3", sender: regular_user, amount_cents: 2000) # self-reload
seed_redemption!(card, marker: "main_1", redeemer: merchant, actor: merchant_user, amount_cents: 6000) # spans loads 1 and 2
card.reload
puts "✅ Demo card ##{card.id} for #{regular_user.email} at #{merchant.store_name}: " \
     "#{card.loads.count} loads, loaded #{card.total_loaded_cents}, balance #{card.remaining_balance}"

# ── duplicate pair for the Phase 2 merge demo ──────────────────────────

if pair_index_exists?
  dup_card = seed_card!(marker: "cs_seed_dup_a", recipient: regular_user, merchant: merchant_two,
                        first_sender: admin, first_amount_cents: 2500)
  seed_load!(dup_card, marker: "cs_seed_dup_a_load", sender: admin, amount_cents: 2500)
  seed_load!(dup_card, marker: "cs_seed_dup_b_load", sender: sender_user, amount_cents: 1500)
  puts "✅ #{merchant_two.store_name} card ##{dup_card.id}: 2 loads (pair index exists, no duplicate seeded)"
else
  dup_a = seed_card!(marker: "cs_seed_dup_a", recipient: regular_user, merchant: merchant_two,
                     first_sender: admin, first_amount_cents: 2500)
  seed_load!(dup_a, marker: "cs_seed_dup_a_load", sender: admin, amount_cents: 2500)
  dup_b = seed_card!(marker: "cs_seed_dup_b", recipient: regular_user, merchant: merchant_two,
                     first_sender: sender_user, first_amount_cents: 1500)
  seed_load!(dup_b, marker: "cs_seed_dup_b_load", sender: sender_user, amount_cents: 1500)
  puts "✅ Duplicate pair seeded at #{merchant_two.store_name}: cards ##{dup_a.id} and ##{dup_b.id} " \
       "(run DRY_RUN=1 bin/rake gift_cards:merge_duplicates)"
end

# ── settlements ────────────────────────────────────────────────────────

if Settlement.count == 0
  Settlement.create!(
    merchant: merchant, amount: 2500, payout_status: :pending,
    period_start: 1.week.ago.to_date, period_end: Date.current,
    notes: "Weekly settlement for demo redemptions"
  )
  puts "✅ Created demo settlement"
end

puts "🎉 Seeding completed!"
puts ""
puts "Login credentials:"
puts "Admin: admin@example.com / password123"
puts "Merchant: merchant@example.com / password123"
puts "Merchant 2: merchant2@example.com / password123"
puts "User: user@example.com / password123"
puts "Sender: sender@example.com / password123"
puts ""
puts "You can now run: rails server"
