require 'rails_helper'

RSpec.describe "Merchant::Settlements", type: :request do
  let(:merchant_user) { create(:user, role: :merchant) }
  let!(:merchant) { create(:merchant, user: merchant_user) }

  let(:other_merchant_user) { create(:user, role: :merchant) }
  let!(:other_merchant) { create(:merchant, user: other_merchant_user, store_name: "Other Store") }

  let(:sender) { create(:user) }
  let(:recipient) { create(:user) }

  before do
    sign_in merchant_user
  end

  describe "GET /merchant/settlements (index)" do
    context "when merchant has redeemed gift cards" do
      it "shows redemptions REDEEMED BY this merchant, not cards issued by them" do
        # Create a gift card issued by OTHER merchant
        gift_card_from_other = create(:gift_card, merchant: other_merchant, sender: sender, recipient: recipient, amount: 5000)

        # Redeem it at OUR merchant (cross-merchant redemption)
        create(:transaction,
          gift_card: gift_card_from_other,
          merchant: merchant,  # redeemer = our merchant
          amount: 2500,
          txn_type: :redemption,
          status: :succeeded,
          currency: "USD",
          processor_ref: "test_#{SecureRandom.hex(4)}"
        )

        get merchant_settlements_path

        expect(response).to have_http_status(:ok)
        # The page should show the gift card that WE REDEEMED
        expect(response.body).to include("Tarjeta ##{gift_card_from_other.id}")
        # Should show the issuing merchant
        expect(response.body).to include("Emitida por: Other Store")
      end

      it "does NOT show redemptions performed by other merchants on cards we issued" do
        # Create a gift card issued by OUR merchant
        gift_card_we_issued = create(:gift_card, merchant: merchant, sender: sender, recipient: recipient, amount: 5000)

        # Someone ELSE redeems it (not us)
        create(:transaction,
          gift_card: gift_card_we_issued,
          merchant: other_merchant,  # redeemer = other merchant
          amount: 2500,
          txn_type: :redemption,
          status: :succeeded,
          currency: "USD",
          processor_ref: "test_#{SecureRandom.hex(4)}"
        )

        get merchant_settlements_path

        expect(response).to have_http_status(:ok)
        # The page should NOT show this gift card because WE didn't redeem it
        expect(response.body).not_to include("Tarjeta ##{gift_card_we_issued.id}")
      end

      it "correctly calculates pending settlement based on transactions redeemed by this merchant" do
        # Create gift cards from different issuers
        gift_card_1 = create(:gift_card, merchant: other_merchant, amount: 10000)
        gift_card_2 = create(:gift_card, merchant: merchant, amount: 8000) # our own card

        # Redeem both at OUR merchant
        create(:transaction, gift_card: gift_card_1, merchant: merchant, amount: 3000, txn_type: :redemption, status: :succeeded, currency: "USD", processor_ref: "t1")
        create(:transaction, gift_card: gift_card_2, merchant: merchant, amount: 4000, txn_type: :redemption, status: :succeeded, currency: "USD", processor_ref: "t2")

        get merchant_settlements_path

        expect(response).to have_http_status(:ok)
        # Total redeemed should be $30 + $40 = $70
        expect(response.body).to include("$70.00")
      end
    end

    context "when merchant has no redemptions" do
      it "shows empty state message" do
        get merchant_settlements_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Aún no registras canjes")
      end
    end

    context "when not logged in" do
      before { sign_out merchant_user }

      it "redirects to login" do
        get merchant_settlements_path
        expect(response).to have_http_status(:found)
      end
    end
  end

  describe "GET /merchant/settlements/:id (show)" do
    let!(:settlement) do
      create(:settlement,
        merchant: merchant,
        amount: 5000,
        period_start: 1.week.ago.to_date,
        period_end: Date.current,
        payout_status: :pending
      )
    end

    it "shows transactions REDEEMED BY this merchant within settlement period" do
      # Create a gift card issued by OTHER merchant
      gift_card = create(:gift_card, merchant: other_merchant, sender: sender, recipient: recipient)

      # Redeem it at OUR merchant within settlement period
      create(:transaction,
        gift_card: gift_card,
        merchant: merchant,
        amount: 2500,
        txn_type: :redemption,
        status: :succeeded,
        created_at: 3.days.ago,
        currency: "USD",
        processor_ref: "test_show"
      )

      get merchant_settlement_path(settlement)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Gift Card ##{gift_card.id}")
      # Should show cross-merchant indicator
      expect(response.body).to include("Emitida por: Other Store")
    end

    it "does NOT show transactions redeemed by other merchants" do
      # Create a gift card issued by OUR merchant
      gift_card = create(:gift_card, merchant: merchant, sender: sender, recipient: recipient)

      # Someone ELSE redeems it within the period
      create(:transaction,
        gift_card: gift_card,
        merchant: other_merchant,
        amount: 2500,
        txn_type: :redemption,
        status: :succeeded,
        created_at: 3.days.ago,
        currency: "USD",
        processor_ref: "test_other"
      )

      get merchant_settlement_path(settlement)

      expect(response).to have_http_status(:ok)
      # The gift card should NOT appear because we didn't redeem it
      expect(response.body).not_to include("Gift Card ##{gift_card.id}")
    end
  end
end
