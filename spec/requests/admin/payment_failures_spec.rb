require "rails_helper"

RSpec.describe "Admin::PaymentFailures", type: :request do
  let(:admin) { create(:user, role: :admin) }

  before { sign_in admin }

  def create_failure(pi:, resolved: false, sender: nil, merchant: nil, attempts: 1)
    PaymentFailure.create!(
      payment_intent_id: pi, amount: 800, currency: "USD",
      sender: sender, merchant: merchant,
      error_code: "card_declined", decline_code: "do_not_honor",
      error_message: "Your card was declined.",
      attempts: attempts,
      first_failed_at: 2.hours.ago, last_failed_at: 1.hour.ago,
      resolved_at: resolved ? 30.minutes.ago : nil
    )
  end

  describe "GET /admin/payment_failures" do
    it "lists unresolved declines by default with buyer and merchant links" do
      buyer = create(:user, first_name: "Decl", last_name: "Inada")
      merchant = create(:merchant, store_name: "Tienda Rechazo")
      create_failure(pi: "pi_open_1", sender: buyer, merchant: merchant, attempts: 5)
      create_failure(pi: "pi_done_1", resolved: true)

      get admin_payment_failures_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("pi_open_1")
      expect(response.body).not_to include("pi_done_1")
      expect(response.body).to include("Decl Inada", "Tienda Rechazo", "do_not_honor")
      expect(response.body).to include(admin_user_path(buyer))
    end

    it "shows resolved declines under the resolved filter" do
      create_failure(pi: "pi_done_2", resolved: true)

      get admin_payment_failures_path(filter: "resolved")

      expect(response.body).to include("pi_done_2")
      expect(response.body).to include("Resuelto")
    end

    it "survives garbage params" do
      get admin_payment_failures_path(filter: "bogus", page: -2)

      expect(response).to have_http_status(:ok)
    end

    it "blocks non-admins" do
      sign_in create(:user)

      get admin_payment_failures_path

      expect(response).to redirect_to(root_path)
    end
  end
end
