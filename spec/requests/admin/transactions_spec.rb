require "rails_helper"

RSpec.describe "Admin::Transactions", type: :request do
  let(:admin) { create(:user, role: :admin) }

  before { sign_in admin }

  def create_txn(gift_card, type:, status: :succeeded, amount: 1_000, ref: "ref_#{SecureRandom.hex(6)}", created_at: Time.current)
    gift_card.transactions.create!(
      amount: amount, txn_type: type, status: status, currency: "USD",
      processor_ref: ref, merchant: gift_card.merchant, user: gift_card.sender, created_at: created_at
    )
  end

  describe "GET /admin/transactions" do
    it "lists the ledger with card, merchant and user links" do
      merchant = create(:merchant, store_name: "Medicity Ledger")
      card = create(:gift_card, merchant: merchant)
      create_txn(card, type: :purchase, ref: "pi_ledger_1")

      get admin_transactions_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("pi_ledger_1")
      expect(response.body).to include("Medicity Ledger")
      expect(response.body).to include("REM-#{card.id.to_s.last(6)}")
      expect(response.body).to include(admin_gift_card_path(card))
    end

    it "filters by type and status" do
      card = create(:gift_card)
      create_txn(card, type: :redemption, ref: "canje_1")
      create_txn(card, type: :refund, status: :failed, ref: "refund_failed_1")

      get admin_transactions_path(type: "refund", status: "failed")

      expect(response.body).to include("refund_failed_1")
      expect(response.body).not_to include("canje_1")
    end

    it "filters by merchant and date range" do
      old_card = create(:gift_card)
      new_card = create(:gift_card)
      create_txn(old_card, type: :purchase, ref: "viejo_1", created_at: 30.days.ago)
      create_txn(new_card, type: :purchase, ref: "nuevo_1")

      get admin_transactions_path(merchant_id: new_card.merchant_id, from: 7.days.ago.to_date.iso8601)

      expect(response.body).to include("nuevo_1")
      expect(response.body).not_to include("viejo_1")
    end

    it "searches by processor reference" do
      card = create(:gift_card)
      create_txn(card, type: :purchase, ref: "pi_findme_99")
      create_txn(card, type: :purchase, ref: "pi_other_11")

      get admin_transactions_path(q: "findme")

      expect(response.body).to include("pi_findme_99")
      expect(response.body).not_to include("pi_other_11")
    end

    it "survives garbage params" do
      get admin_transactions_path(type: "bogus", status: "junk", merchant_id: "x", from: "not-a-date", to: "1234", page: -9, q: "'\"%_zz")

      expect(response).to have_http_status(:ok)
    end

    it "blocks non-admins" do
      sign_in create(:user)

      get admin_transactions_path

      expect(response).to redirect_to(root_path)
    end
  end
end
