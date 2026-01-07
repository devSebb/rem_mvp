class CreateUserSessions < ActiveRecord::Migration[7.2]
  def change
    create_table :user_sessions do |t|
      t.references :user, null: false, foreign_key: true
      t.string :refresh_token_digest, null: false
      t.string :device_id
      t.string :ip
      t.string :user_agent
      t.datetime :last_used_at
      t.datetime :revoked_at

      t.timestamps
    end

    add_index :user_sessions, :refresh_token_digest, unique: true
    add_index :user_sessions, :revoked_at
  end
end

