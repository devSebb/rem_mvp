require "digest"
require "securerandom"

class AddApiCredentialsToMerchants < ActiveRecord::Migration[7.2]
  class Merchant < ApplicationRecord
    self.table_name = "merchants"
  end

  def up
    add_column :merchants, :name, :string
    add_column :merchants, :status, :integer, default: 0, null: false
    add_column :merchants, :public_key, :string
    add_column :merchants, :secret_key_digest, :string

    add_index :merchants, :public_key, unique: true
    add_index :merchants, :secret_key_digest, unique: true

    Merchant.reset_column_information

    say_with_time "Backfilling merchant API credentials" do
      Merchant.find_each do |merchant|
        merchant.update_columns(
          name: merchant.name.presence || merchant.store_name.presence || "Merchant #{merchant.id}",
          public_key: merchant.public_key.presence || generate_public_key,
          secret_key_digest: merchant.secret_key_digest.presence || digest_secret(SecureRandom.hex(32))
        )
      end
    end

    change_column_null :merchants, :name, false
    change_column_null :merchants, :public_key, false
    change_column_null :merchants, :secret_key_digest, false
  end

  def down
    remove_index :merchants, :public_key
    remove_index :merchants, :secret_key_digest

    remove_column :merchants, :name
    remove_column :merchants, :status
    remove_column :merchants, :public_key
    remove_column :merchants, :secret_key_digest
  end

  private

  def digest_secret(raw)
    Digest::SHA256.hexdigest(raw)
  end

  def generate_public_key
    "pub_#{SecureRandom.hex(16)}"
  end
end

