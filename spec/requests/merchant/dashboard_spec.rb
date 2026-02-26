require 'rails_helper'

RSpec.describe "Merchant::Dashboards", type: :request do
  let(:merchant_user) { create(:user, role: :merchant) }
  let!(:merchant) { create(:merchant, user: merchant_user, store_name: "Our Store") }

  let(:other_merchant_user) { create(:user, role: :merchant) }
  let!(:other_merchant) { create(:merchant, user: other_merchant_user, store_name: "Other Store") }

  let(:sender) { create(:user, first_name: "John", last_name: "Sender") }
  let(:recipient) { create(:user, first_name: "Jane", last_name: "Recipient") }

  describe "GET /merchant (index)" do
    context "when not logged in" do
      it "redirects to login" do
        get "/merchant"
        expect(response).to have_http_status(:found)
      end
    end

    context "when logged in as merchant" do
      before { sign_in merchant_user }

      it "returns http success" do
        get "/merchant"
        expect(response).to have_http_status(:ok)
      end

      it "returns response contract: dashboard page with key sections" do
        get "/merchant"
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Comercio", "Canjear", "Liquidaciones")
      end

      it "shows redemptions REDEEMED BY this merchant (redeemer-paid model)" do
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

        get "/merchant"

        expect(response).to have_http_status(:ok)
        # Should show the redemption transaction
        expect(response.body).to include("$25.00")
        # Should show sender info
        expect(response.body).to include("John Sender")
        # Should indicate cross-merchant with "Emisor" column showing the issuer
        expect(response.body).to include("Other Store")
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

        get "/merchant"

        expect(response).to have_http_status(:ok)
        # Should NOT show this transaction in the recent redemptions
        # The pending settlement should be $0 (no redemptions by us)
        # Check that Other Store's redemption is NOT listed
        expect(response.body).not_to include("De John Sender") # The sender of the card we issued
      end

      it "correctly calculates pending settlement as sum of transactions REDEEMED BY this merchant" do
        # Create gift cards from different issuers
        gift_card_from_other = create(:gift_card, merchant: other_merchant, sender: sender, recipient: recipient, amount: 10000)
        gift_card_our_own = create(:gift_card, merchant: merchant, sender: sender, recipient: recipient, amount: 8000)

        # Redeem both at OUR merchant
        create(:transaction, gift_card: gift_card_from_other, merchant: merchant, amount: 3000, txn_type: :redemption, status: :succeeded, currency: "USD", processor_ref: "t1")
        create(:transaction, gift_card: gift_card_our_own, merchant: merchant, amount: 4000, txn_type: :redemption, status: :succeeded, currency: "USD", processor_ref: "t2")

        get "/merchant"

        expect(response).to have_http_status(:ok)
        # Total pending settlement should be $30 + $40 = $70
        expect(response.body).to include("$70.00")
      end

      it "shows 'Tu comercio' for self-issued cards redeemed by us" do
        # Create a gift card issued by OUR merchant
        gift_card_our_own = create(:gift_card, merchant: merchant, sender: sender, recipient: recipient, amount: 5000)

        # Redeem it at OUR merchant (same-merchant redemption)
        create(:transaction,
          gift_card: gift_card_our_own,
          merchant: merchant,
          amount: 2500,
          txn_type: :redemption,
          status: :succeeded,
          currency: "USD",
          processor_ref: "test_self"
        )

        get "/merchant"

        expect(response).to have_http_status(:ok)
        # Should show "Tu comercio" in the Emisor column for our own cards
        expect(response.body).to include("Tu comercio")
      end
    end
  end
end
