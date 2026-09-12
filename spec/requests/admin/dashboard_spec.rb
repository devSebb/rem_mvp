require "rails_helper"

RSpec.describe "Admin::Dashboard", type: :request do
  let(:admin) { create(:user, role: :admin) }

  describe "GET /admin" do
    it "renders the command center for admins" do
      merchant = create(:merchant, store_name: "Farmacia Central")
      card = create(:gift_card, merchant: merchant, amount: 5_000)
      Transaction.create!(
        gift_card: card,
        merchant: merchant,
        amount: 5_000,
        txn_type: :purchase,
        status: :succeeded,
        processor_ref: "pi_dash_#{SecureRandom.hex(4)}",
        currency: "USD",
        metadata: { fee_cents: 130, stripe_fee_cents: 175 }
      )

      sign_in admin
      get admin_root_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Centro de control")
      expect(response.body).to include("Farmacia Central")
      # Fee revenue and Stripe cost tiles read from ledger metadata
      expect(response.body).to include("$1.30")
      expect(response.body).to include("$1.75")
      # Outstanding liability from active + frozen card balances
      expect(response.body).to include("$50.00")
    end

    it "shows the §9 KPIs: frozen cards, disputed cents, remittance counter and last reconcile" do
      merchant = create(:merchant)
      frozen = create(:gift_card, merchant: merchant, amount: 0, status: :frozen_by_admin)
      stripe_load!(frozen, 4_000, sender: create(:user, country_of_residence: "US"))
      disputed = create(:gift_card, merchant: merchant, amount: 0)
      stripe_load!(disputed, 2_500, sender: create(:user, country_of_residence: "EC"), disputed_at: 1.hour.ago)
      Rails.cache.write(Ledger::ReconcileJob::LAST_RESULT_KEY, { ran_at: Time.current.iso8601, drift_count: 0, cards_checked: 2 })

      sign_in admin
      get admin_root_path

      expect(response.body).to include("1 congelada")
      expect(response.body).to include("1 en disputa · $25.00")
      expect(response.body).to include("$65.00") # liability incl. frozen
      expect(response.body).to include("Contador CFPB (§4.5)")
      expect(response.body).to include("sin desvíos")
    end

    it "blocks non-admins" do
      sign_in create(:user)

      get admin_root_path

      expect(response).to redirect_to(root_path)
    end

    it "redirects admins from /home to the command center" do
      sign_in admin

      get home_path

      expect(response).to redirect_to(admin_root_path)
    end

    it "sends admins to the command center after sign-in" do
      admin_user = create(:user, role: :admin, password: "password123")

      post user_session_path, params: { user: { email: admin_user.email, password: "password123" } }

      expect(response).to redirect_to(admin_root_path)
    end
  end
end
