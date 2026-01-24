# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.2].define(version: 2026_01_24_223150) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "gift_cards", force: :cascade do |t|
    t.bigint "sender_id", null: false
    t.bigint "recipient_id", null: false
    t.bigint "merchant_id"
    t.integer "amount", null: false
    t.string "currency", default: "USD", null: false
    t.string "code_digest", null: false
    t.integer "status", default: 0, null: false
    t.datetime "redeemed_at"
    t.datetime "expires_at"
    t.string "checkout_session_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "link_token_digest"
    t.datetime "link_token_expires_at"
    t.string "otp_digest"
    t.datetime "otp_expires_at"
    t.boolean "sent_via_whatsapp", default: false, null: false
    t.boolean "sent_via_sms", default: false, null: false
    t.boolean "sent_via_email", default: false, null: false
    t.integer "remaining_balance", default: 0
    t.text "encrypted_raw_code"
    t.datetime "last_owner_activity_at"
    t.string "payment_intent_id"
    t.text "note"
    t.index ["checkout_session_id"], name: "index_gift_cards_on_checkout_session_id", unique: true
    t.index ["code_digest"], name: "index_gift_cards_on_code_digest", unique: true
    t.index ["encrypted_raw_code"], name: "index_gift_cards_on_encrypted_raw_code", where: "(encrypted_raw_code IS NOT NULL)"
    t.index ["last_owner_activity_at"], name: "index_gift_cards_on_last_owner_activity_at"
    t.index ["link_token_digest"], name: "index_gift_cards_on_link_token_digest", unique: true
    t.index ["merchant_id"], name: "index_gift_cards_on_merchant_id"
    t.index ["otp_digest"], name: "index_gift_cards_on_otp_digest", unique: true
    t.index ["payment_intent_id"], name: "index_gift_cards_on_payment_intent_id", unique: true, where: "(payment_intent_id IS NOT NULL)"
    t.index ["recipient_id"], name: "index_gift_cards_on_recipient_id"
    t.index ["sender_id"], name: "index_gift_cards_on_sender_id"
    t.index ["status"], name: "index_gift_cards_on_status"
  end

  create_table "merchants", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "store_name", null: false
    t.text "address"
    t.string "contact_email"
    t.string "bank_account_iban"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "name", null: false
    t.integer "status", default: 0, null: false
    t.string "public_key", null: false
    t.string "secret_key_digest", null: false
    t.string "avatar_url"
    t.string "categories", default: [], array: true
    t.index ["public_key"], name: "index_merchants_on_public_key", unique: true
    t.index ["secret_key_digest"], name: "index_merchants_on_secret_key_digest", unique: true
    t.index ["store_name"], name: "index_merchants_on_store_name"
    t.index ["user_id"], name: "index_merchants_on_user_id"
  end

  create_table "redemption_tokens", force: :cascade do |t|
    t.bigint "gift_card_id", null: false
    t.string "token_digest", null: false
    t.datetime "expires_at", null: false
    t.datetime "used_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_redemption_tokens_on_expires_at"
    t.index ["gift_card_id", "expires_at"], name: "index_redemption_tokens_on_gift_card_id_and_expires_at"
    t.index ["gift_card_id"], name: "index_redemption_tokens_on_gift_card_id"
    t.index ["token_digest"], name: "index_redemption_tokens_on_token_digest", unique: true
  end

  create_table "settlements", force: :cascade do |t|
    t.bigint "merchant_id", null: false
    t.integer "amount", null: false
    t.integer "payout_status", default: 0, null: false
    t.date "period_start", null: false
    t.date "period_end", null: false
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["merchant_id"], name: "index_settlements_on_merchant_id"
    t.index ["payout_status"], name: "index_settlements_on_payout_status"
    t.index ["period_start", "period_end"], name: "index_settlements_on_period_start_and_period_end"
  end

  create_table "transactions", force: :cascade do |t|
    t.bigint "gift_card_id"
    t.integer "amount", null: false
    t.integer "txn_type", null: false
    t.integer "status", default: 0, null: false
    t.string "processor_ref"
    t.jsonb "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "merchant_id"
    t.bigint "user_id"
    t.bigint "redemption_token_id"
    t.string "currency"
    t.string "idempotency_key"
    t.string "decline_reason"
    t.string "merchant_reference"
    t.index ["gift_card_id"], name: "index_transactions_on_gift_card_id"
    t.index ["merchant_id", "idempotency_key"], name: "index_transactions_on_merchant_id_and_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["merchant_id"], name: "index_transactions_on_merchant_id"
    t.index ["metadata"], name: "index_transactions_on_metadata", using: :gin
    t.index ["redemption_token_id"], name: "index_transactions_on_redemption_token_id"
    t.index ["status"], name: "index_transactions_on_status"
    t.index ["txn_type"], name: "index_transactions_on_txn_type"
    t.index ["user_id"], name: "index_transactions_on_user_id"
  end

  create_table "user_sessions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "refresh_token_digest", null: false
    t.string "device_id"
    t.string "ip"
    t.string "user_agent"
    t.datetime "last_used_at"
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["refresh_token_digest"], name: "index_user_sessions_on_refresh_token_digest", unique: true
    t.index ["revoked_at"], name: "index_user_sessions_on_revoked_at"
    t.index ["user_id"], name: "index_user_sessions_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.string "name", null: false
    t.string "phone"
    t.integer "role", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "national_id"
    t.string "first_name"
    t.string "last_name"
    t.string "address"
    t.string "country_of_residence"
    t.date "date_of_birth"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["national_id"], name: "index_users_on_national_id", unique: true
    t.index ["phone"], name: "index_users_on_phone", unique: true, where: "(phone IS NOT NULL)"
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["role"], name: "index_users_on_role"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "gift_cards", "merchants"
  add_foreign_key "gift_cards", "users", column: "recipient_id"
  add_foreign_key "gift_cards", "users", column: "sender_id"
  add_foreign_key "merchants", "users"
  add_foreign_key "redemption_tokens", "gift_cards"
  add_foreign_key "settlements", "merchants"
  add_foreign_key "transactions", "gift_cards"
  add_foreign_key "transactions", "merchants"
  add_foreign_key "transactions", "redemption_tokens"
  add_foreign_key "transactions", "users"
  add_foreign_key "user_sessions", "users"
end
