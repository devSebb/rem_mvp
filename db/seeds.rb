# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

puts "🌱 Seeding database..."

# Create admin user
admin = User.find_or_create_by!(email: 'admin@example.com') do |user|
  user.name = 'Admin User'
  user.password = 'password123'
  user.password_confirmation = 'password123'
  user.role = :admin
end

puts "✅ Created admin user: #{admin.email}"

# Create merchant user
merchant_user = User.find_or_create_by!(email: 'merchant@example.com') do |user|
  user.name = 'Merchant Owner'
  user.password = 'password123'
  user.password_confirmation = 'password123'
  user.role = :merchant
  user.phone = '+1234567890'
end

merchant = Merchant.find_or_create_by!(user: merchant_user) do |m|
  m.store_name = 'Demo Store'
  m.address = '123 Main Street, City, State 12345'
  m.contact_email = 'merchant@example.com'
  m.bank_account_iban = 'US12345678901234567890'
end

puts "✅ Created merchant: #{merchant.store_name}"

# Create regular user
regular_user = User.find_or_create_by!(email: 'user@example.com') do |user|
  user.name = 'Regular User'
  user.password = 'password123'
  user.password_confirmation = 'password123'
  user.role = :user
  user.phone = '+1987654321'
end

puts "✅ Created regular user: #{regular_user.email}"

# Create some demo gift cards
if GiftCard.count == 0
  # Active gift card
  active_gift_card = GiftCard.new(
    sender: admin,
    recipient: regular_user,
    merchant: merchant,
    amount: 5000, # $50.00
    currency: 'USD',
    checkout_session_id: 'cs_demo_active',
    expires_at: 1.year.from_now
  )
  active_gift_card.generate_code!
  
  # Test gift card with known code for easy redemption testing
  test_gift_card = GiftCard.new(
    sender: admin,
    recipient: regular_user,
    merchant: merchant,
    amount: 3000, # $30.00
    currency: 'USD',
    checkout_session_id: 'cs_demo_test',
    expires_at: 1.year.from_now
  )
  # Set a known test code instead of generating a random one
  test_code = "REM-TEST-1234-5678"
  test_gift_card.code_digest = BCrypt::Password.create(test_code)
  test_gift_card.save!
  
  # Additional test gift card with different code for testing
  test_gift_card_2 = GiftCard.new(
    sender: admin,
    recipient: regular_user,
    merchant: merchant,
    amount: 2000, # $20.00
    currency: 'USD',
    checkout_session_id: 'cs_demo_test_2',
    expires_at: 1.year.from_now
  )
  # Set another known test code
  test_code_2 = "REM-TEST-ABCD-EFGH"
  test_gift_card_2.code_digest = BCrypt::Password.create(test_code_2)
  test_gift_card_2.save!
  
  # Redeemed gift card
  redeemed_gift_card = GiftCard.new(
    sender: regular_user,
    recipient: merchant_user,
    merchant: merchant,
    amount: 2500, # $25.00
    currency: 'USD',
    checkout_session_id: 'cs_demo_redeemed',
    status: :redeemed,
    redeemed_at: 1.day.ago
  )
  redeemed_gift_card.generate_code!
  redeemed_gift_card.save!
  redeemed_gift_card.redeem!(merchant: merchant, actor: merchant_user)
  
  # Expired gift card
  expired_gift_card = GiftCard.new(
    sender: admin,
    recipient: regular_user,
    merchant: merchant,
    amount: 1000, # $10.00
    currency: 'USD',
    checkout_session_id: 'cs_demo_expired',
    status: :expired,
    expires_at: 1.day.ago
  )
  expired_gift_card.generate_code!
  
  puts "✅ Created demo gift cards"
  puts "🧪 Test gift card codes:"
  puts "   - #{test_code} ($30.00)"
  puts "   - #{test_code_2} ($20.00)"
  puts "   Use these codes for easy redemption testing!"
end

# Create some settlements
if Settlement.count == 0
  Settlement.create!(
    merchant: merchant,
    amount: 2500, # $25.00
    payout_status: :pending,
    period_start: 1.week.ago.to_date,
    period_end: Date.current,
    notes: 'Weekly settlement for demo redemptions'
  )
  
  puts "✅ Created demo settlements"
end

puts "🎉 Seeding completed!"
puts ""
puts "Login credentials:"
puts "Admin: admin@example.com / password123"
puts "Merchant: merchant@example.com / password123"
puts "User: user@example.com / password123"
puts ""
puts "You can now run: rails server"
