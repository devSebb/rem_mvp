require "rails_helper"

RSpec.describe "Admin::Merchants", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:user, role: :admin) }

  before { sign_in admin }

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
      merchant = create(:merchant)
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
