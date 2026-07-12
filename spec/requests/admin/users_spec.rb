require "rails_helper"

RSpec.describe "Admin::Users", type: :request do
  let(:admin) { create(:user, role: :admin) }

  before { sign_in admin }

  describe "GET /admin/users" do
    it "lists consumer accounts only" do
      consumer = create(:user, first_name: "Carla", last_name: "Mora")
      merchant_user = create(:user, role: :merchant, first_name: "Tienda", last_name: "Dueño")

      get admin_users_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Carla Mora")
      expect(response.body).not_to include("Tienda Dueño")
    end

    it "searches by email" do
      create(:user, email: "buscame@example.com", first_name: "Búsqueda", last_name: "Feliz")
      create(:user, first_name: "Otra", last_name: "Persona")

      get admin_users_path(q: "buscame")

      expect(response.body).to include("Búsqueda Feliz")
      expect(response.body).not_to include("Otra Persona")
    end

    it "filters pending recipients" do
      User.create!(
        name: "Destinataria Pendiente",
        email: "pending@example.com",
        password: SecureRandom.hex(16),
        role: :user,
        pending_recipient: true
      )
      create(:user, first_name: "Reclamada", last_name: "Cuenta")

      get admin_users_path(filter: "pending")

      expect(response.body).to include("pending@example.com")
      expect(response.body).not_to include("Reclamada Cuenta")
    end

    it "blocks non-admins" do
      sign_in create(:user)

      get admin_users_path

      expect(response).to redirect_to(root_path)
    end
  end

  describe "GET /admin/users/:id" do
    it "shows account details, balance and activity" do
      user = create(:user, first_name: "Diana", last_name: "Vera")
      merchant = create(:merchant)
      create(:gift_card, recipient: user, merchant: merchant, amount: 3_000)

      get admin_user_path(user)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Diana Vera")
      expect(response.body).to include("$30.00")
      expect(response.body).to include(user.email)
    end
  end
end
