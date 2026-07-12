require "rails_helper"

RSpec.describe "Admin::Payouts", type: :request do
  let(:admin) { create(:user, role: :admin) }
  let(:merchant) { create(:merchant) }

  before { sign_in admin }

  def create_redemption!(amount_cents)
    gift_card = create(:gift_card, merchant: merchant, amount: amount_cents)
    Transaction.create!(
      gift_card: gift_card,
      merchant: merchant,
      amount: amount_cents,
      txn_type: :redemption,
      status: :succeeded,
      processor_ref: "red_#{SecureRandom.hex(6)}",
      currency: "USD",
      metadata: {}
    )
  end

  describe "POST /admin/payouts (create settlement)" do
    it "settles the full redeemed amount with launch pricing (0% commission)" do
      create_redemption!(10_000)

      expect {
        post admin_payouts_path(merchant_id: merchant.id)
      }.to change(Settlement, :count).by(1)

      settlement = Settlement.last
      expect(settlement.amount).to eq(10_000)
      expect(settlement.gross_amount).to eq(10_000)
      expect(settlement.commission_amount).to eq(0)
      expect(settlement.commission_bps).to eq(0)
      expect(settlement.amount_matches_calculated?).to be(true)
    end

    it "withholds the configured merchant commission" do
      PlatformSetting.current.update!(merchant_commission_bps: 500)
      create_redemption!(10_000)

      post admin_payouts_path(merchant_id: merchant.id)

      settlement = Settlement.last
      expect(settlement.gross_amount).to eq(10_000)
      expect(settlement.commission_amount).to eq(500)
      expect(settlement.commission_bps).to eq(500)
      expect(settlement.amount).to eq(9_500)
      expect(settlement.amount_matches_calculated?).to be(true)
    end
  end

  describe "GET /admin/payouts" do
    it "renders the payout summary" do
      create_redemption!(5_000)

      get admin_payouts_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(merchant.store_name)
    end
  end
end
