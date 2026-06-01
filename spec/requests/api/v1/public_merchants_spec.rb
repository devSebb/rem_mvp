require "rails_helper"

RSpec.describe "Api::V1::Public::Merchants", type: :request do
  describe "GET /api/v1/public/merchants" do
    it "allows anonymous users to browse active merchants" do
      active = create(:merchant, store_name: "Mercado Central", categories: ["supermercado"])
      create(:merchant, store_name: "Hidden Store", status: :suspended)

      get "/api/v1/public/merchants"

      expect(response).to have_http_status(:ok)
      expect(parsed_data.map { |merchant| merchant["id"] }).to contain_exactly(active.id)
      expect(parsed_data.first).to include(
        "id" => active.id,
        "store_name" => "Mercado Central",
        "name" => "Mercado Central",
        "address" => active.address,
        "categories" => ["supermercado"],
        "logo_url" => nil
      )
      expect(parsed_data.first).not_to have_key("contact_email")
      expect(parsed_data.first).not_to have_key("public_key")
      expect(parsed_data.first).not_to have_key("secret_key_digest")
    end

    it "filters active merchants by category" do
      bakery = create(:merchant, store_name: "Pan Fresco", categories: ["restaurantes"])
      create(:merchant, store_name: "Farmacia Norte", categories: ["salud_y_medicina"])

      get "/api/v1/public/merchants", params: { category: "restaurantes" }

      expect(response).to have_http_status(:ok)
      expect(parsed_data.map { |merchant| merchant["id"] }).to eq([bakery.id])
    end
  end

  describe "GET /api/v1/public/merchants/:id" do
    it "allows anonymous users to view an active merchant" do
      merchant = create(:merchant, categories: ["salud_y_medicina"])

      get "/api/v1/public/merchants/#{merchant.id}"

      expect(response).to have_http_status(:ok)
      expect(parsed_data["id"]).to eq(merchant.id)
      expect(parsed_data["categories"]).to eq(["salud_y_medicina"])
      expect(parsed_data).not_to have_key("contact_email")
    end

    it "does not expose suspended merchants" do
      merchant = create(:merchant, status: :suspended)

      get "/api/v1/public/merchants/#{merchant.id}"

      expect(response).to have_http_status(:not_found)
    end
  end

  def parsed_body
    JSON.parse(response.body)
  end

  def parsed_data
    parsed_body["data"]
  end
end
