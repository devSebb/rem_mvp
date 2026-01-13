class AddFirstAndLastNameToUsers < ActiveRecord::Migration[7.2]
  def up
    add_column :users, :first_name, :string unless column_exists?(:users, :first_name)
    add_column :users, :last_name, :string unless column_exists?(:users, :last_name)

    say_with_time "Backfilling first_name and last_name from name" do
      migration_user.reset_column_information

      migration_user.find_each do |user|
        next if user.first_name.present? || user.last_name.present?

        first, last = split_name(user.name)
        user.update_columns(first_name: first, last_name: last)
      end
    end
  end

  def down
    remove_column :users, :first_name if column_exists?(:users, :first_name)
    remove_column :users, :last_name if column_exists?(:users, :last_name)
  end

  private

  def migration_user
    @migration_user ||= Class.new(ApplicationRecord) do
      self.table_name = "users"
    end
  end

  def split_name(full_name)
    return [nil, nil] if full_name.blank?

    parts = full_name.to_s.strip.split(/\s+/, 2)
    [parts.first, parts.second.to_s]
  end
end

