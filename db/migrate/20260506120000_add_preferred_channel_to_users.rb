class AddPreferredChannelToUsers < ActiveRecord::Migration[7.2]
  def change
    # 0 = whatsapp (default), 1 = sms
    # Existing users get whatsapp automatically; can be changed via profile settings.
    add_column :users, :preferred_channel, :integer, default: 0, null: false
  end
end
