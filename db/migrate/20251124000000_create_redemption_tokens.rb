class CreateRedemptionTokens < ActiveRecord::Migration[7.2]
  def change
    create_table :redemption_tokens do |t|
      t.references :gift_card, null: false, foreign_key: true
      t.string :token_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :used_at

      t.timestamps
    end

    add_index :redemption_tokens, :token_digest, unique: true
    add_index :redemption_tokens, :expires_at
    add_index :redemption_tokens, [:gift_card_id, :expires_at]
  end
end






