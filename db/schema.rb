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

ActiveRecord::Schema[7.2].define(version: 2025_09_29_031235) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "gift_cards", force: :cascade do |t|
    t.bigint "sender_id", null: false
    t.bigint "recipient_id"
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
    t.index ["checkout_session_id"], name: "index_gift_cards_on_checkout_session_id", unique: true
    t.index ["code_digest"], name: "index_gift_cards_on_code_digest", unique: true
    t.index ["merchant_id"], name: "index_gift_cards_on_merchant_id"
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
    t.index ["store_name"], name: "index_merchants_on_store_name"
    t.index ["user_id"], name: "index_merchants_on_user_id"
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
    t.bigint "gift_card_id", null: false
    t.integer "amount", null: false
    t.integer "txn_type", null: false
    t.integer "status", default: 0, null: false
    t.string "processor_ref"
    t.jsonb "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["gift_card_id"], name: "index_transactions_on_gift_card_id"
    t.index ["metadata"], name: "index_transactions_on_metadata", using: :gin
    t.index ["status"], name: "index_transactions_on_status"
    t.index ["txn_type"], name: "index_transactions_on_txn_type"
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
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["phone"], name: "index_users_on_phone", unique: true, where: "(phone IS NOT NULL)"
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["role"], name: "index_users_on_role"
  end

  add_foreign_key "gift_cards", "merchants"
  add_foreign_key "gift_cards", "users", column: "recipient_id"
  add_foreign_key "gift_cards", "users", column: "sender_id"
  add_foreign_key "merchants", "users"
  add_foreign_key "settlements", "merchants"
  add_foreign_key "transactions", "gift_cards"
end
