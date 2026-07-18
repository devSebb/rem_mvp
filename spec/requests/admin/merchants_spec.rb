require "rails_helper"

RSpec.describe "Admin::Merchants", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:user, role: :admin) }

  before { sign_in admin }

  describe "GET /admin/merchants" do
    it "lists merchants with their card stats" do
      merchant = create(:merchant, store_name: "Tienda Uno")
      create(:gift_card, merchant: merchant, amount: 5000)

      get admin_merchants_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Tienda Uno")
      expect(response.body).to include("$50.00")
    end

    it "filters by status" do
      create(:merchant, store_name: "Activo SA", status: :active)
      create(:merchant, store_name: "Suspendido SA", status: :suspended)

      get admin_merchants_path(filter: "suspended")

      expect(response.body).to include("Suspendido SA")
      expect(response.body).not_to include("Activo SA")
    end

    it "searches by store name and owner email" do
      owner = create(:user, email: "dueno@ejemplo.com")
      create(:merchant, store_name: "Cafetería Luna", user: owner, contact_email: nil)
      create(:merchant, store_name: "Otra Tienda")

      get admin_merchants_path(q: "dueno@ejemplo")

      expect(response.body).to include("Cafetería Luna")
      expect(response.body).not_to include("Otra Tienda")
    end

    it "paginates results" do
      create_list(:merchant, Admin::MerchantsController::PER_PAGE + 1)

      get admin_merchants_path(page: 2)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Página 2 de 2")
    end
  end

  describe "GET /admin/merchants/:id" do
    it "shows stats, gift cards, transactions and settlements" do
      merchant = create(:merchant)
      gift_card = create(:gift_card, merchant: merchant, amount: 7500)
      gift_card.partial_redeem!(redemption_amount: 2500, merchant: merchant, actor: merchant.user)
      create(:settlement, merchant: merchant, amount: 2500)

      get admin_merchant_path(merchant)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("REM-#{gift_card.id.to_s.last(6)}")
      expect(response.body).to include("Transacciones recientes")
      expect(response.body).to include("Liquidaciones")
      expect(response.body).to include("$25.00") # redeemed volume
    end

    it "filters gift cards by status" do
      merchant = create(:merchant)
      active_card = create(:gift_card, merchant: merchant, status: :active)
      redeemed_card = create(:gift_card, merchant: merchant)
      redeemed_card.redeem!(merchant: merchant, actor: merchant.user)

      get admin_merchant_path(merchant, cards: "redeemed")

      expect(response.body).to include("REM-#{redeemed_card.id.to_s.last(6)}")
      expect(response.body).not_to include("REM-#{active_card.id.to_s.last(6)}")
    end
  end

  describe "PATCH /admin/merchants/:id/suspend" do
    it "suspends the merchant" do
      merchant = create(:merchant, status: :active)

      patch suspend_admin_merchant_path(merchant)

      expect(response).to redirect_to(admin_merchant_path(merchant))
      expect(merchant.reload).to be_suspended
    end
  end

  describe "PATCH /admin/merchants/:id/reactivate" do
    it "reactivates the merchant" do
      merchant = create(:merchant, status: :suspended)

      patch reactivate_admin_merchant_path(merchant)

      expect(response).to redirect_to(admin_merchant_path(merchant))
      expect(merchant.reload).to be_active
    end
  end

  describe "POST /admin/merchants/:id/regenerate_secret" do
    it "rotates the merchant secret and exposes the new secret once" do
      old_secret = "sec_old_secret"
      merchant = create(:merchant, secret_key_digest: Merchant.digest_secret(old_secret))

      post regenerate_secret_admin_merchant_path(merchant)

      expect(response).to redirect_to(admin_merchant_path(merchant))
      merchant.reload
      expect(merchant.authenticate_secret(old_secret)).to be(false)
      expect(flash[:generated_secret_key]).to start_with("sec_")
      expect(merchant.authenticate_secret(flash[:generated_secret_key])).to be(true)
    end
  end

  describe "DELETE /admin/merchants/:id" do
    it "deletes an unused merchant and its merchant login" do
      merchant = create(:merchant, user: create(:user, role: :merchant))
      merchant_user = merchant.user

      expect do
        delete admin_merchant_path(merchant)
      end.to change(Merchant, :count).by(-1)
        .and change(User, :count).by(-1)

      expect(response).to redirect_to(admin_merchants_path)
      expect(User.exists?(merchant_user.id)).to be(false)
    end

    it "blocks deletion when the merchant has gift-card history" do
      merchant = create(:merchant)
      create(:gift_card, merchant: merchant)

      expect do
        delete admin_merchant_path(merchant)
      end.not_to change(Merchant, :count)

      expect(response).to redirect_to(admin_merchant_path(merchant))
      expect(merchant.reload).to be_present
    end
  end
end
