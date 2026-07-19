# Failed purchase attempts (payment_intent.payment_failed). One row per
# PaymentIntent — repeat declines increment attempts instead of piling up
# rows, since Stripe emits one event per retry.
class CreatePaymentFailures < ActiveRecord::Migration[7.2]
  def change
    create_table :payment_failures do |t|
      t.string :payment_intent_id, null: false
      t.integer :amount, null: false, default: 0
      t.string :currency, null: false, default: "USD"
      t.bigint :sender_id
      t.bigint :merchant_id
      t.string :error_code
      t.string :decline_code
      t.string :error_message
      t.integer :attempts, null: false, default: 1
      t.datetime :first_failed_at, null: false
      t.datetime :last_failed_at, null: false
      t.datetime :resolved_at
      t.timestamps
    end

    add_index :payment_failures, :payment_intent_id, unique: true
    add_index :payment_failures, :last_failed_at
    add_index :payment_failures, :sender_id
    add_index :payment_failures, :merchant_id
  end
end
