class CreatePushTokens < ActiveRecord::Migration[7.2]
  def change
    create_table :push_tokens do |t|
      t.references :user, null: false, foreign_key: true
      t.string :token, null: false
      t.string :platform, null: false
      t.boolean :active, default: true, null: false
      t.timestamps
    end

    add_index :push_tokens, :token, unique: true
    add_index :push_tokens, [:user_id, :active]
  end
end
