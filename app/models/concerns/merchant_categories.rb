module MerchantCategories
  extend ActiveSupport::Concern

  VALID_CATEGORIES = %w[
    salud_y_medicina
    mascotas
    servicios
    supermercado
    hogar
    tecnologia
    ropa_y_moda
    belleza
    deportes_y_fitness
    entretenimiento
    restaurantes
    educacion
    viajes
    bebes_y_ninos
  ].freeze

  CATEGORY_LABELS = {
    "salud_y_medicina"   => "Salud y medicina",
    "mascotas"           => "Mascotas",
    "servicios"          => "Servicios",
    "supermercado"       => "Supermercado",
    "hogar"              => "Hogar",
    "tecnologia"         => "Tecnología",
    "ropa_y_moda"        => "Ropa y moda",
    "belleza"            => "Belleza",
    "deportes_y_fitness" => "Deportes y fitness",
    "entretenimiento"    => "Entretenimiento",
    "restaurantes"       => "Restaurantes",
    "educacion"          => "Educación",
    "viajes"             => "Viajes",
    "bebes_y_ninos"      => "Bebés y niños"
  }.freeze

  included do
    before_validation :normalize_categories
    validate :categories_must_be_valid
  end

  private

  def normalize_categories
    self.categories = (categories || []).reject(&:blank?)
  end

  def categories_must_be_valid
    return if categories.blank?

    invalid = categories - MerchantCategories::VALID_CATEGORIES
    return if invalid.empty?

    errors.add(:categories, "contiene categorías no válidas: #{invalid.join(', ')}")
  end
end
