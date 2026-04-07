class SeedMerchantCategories < ActiveRecord::Migration[7.2]
  # Maps canonical category keys to store names in production.
  # Only updates the categories column on existing rows — no records are created.
  CATEGORY_MAP = {
    "salud_y_medicina" => ["Medicity", "Farmacias Económicas", "Salud S.A."],
    "hogar"            => ["Mascotas"],
    "tecnologia"       => ["Movistar", "Tuenti"]
  }.freeze

  def up
    CATEGORY_MAP.each do |category, store_names|
      ids = Merchant.where(store_name: store_names).pluck(:id)
      next if ids.empty?

      Merchant.where(id: ids).update_all(
        "categories = ARRAY['#{category}']::varchar[]"
      )
    end
  end

  def down
    store_names = CATEGORY_MAP.values.flatten
    Merchant.where(store_name: store_names).update_all(categories: [])
  end
end
