require "rails_helper"

RSpec.describe "Admin::GiftCards", type: :request do
  let(:admin) { create(:user, role: :admin) }

  before { sign_in admin }

  describe "GET /admin/gift_cards" do
    it "lists every card on the platform" do
      merchant = create(:merchant, store_name: "Luccianos")
      buyer = create(:user, first_name: "Bruno", last_name: "Comprador")
      create(:gift_card, sender: buyer, merchant: merchant, amount: 3_000)

      get admin_gift_cards_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Luccianos")
      expect(response.body).to include("Bruno Comprador")
    end

    it "filters disputed cards" do
      merchant = create(:merchant)
      disputed = create(:gift_card, merchant: merchant, disputed_at: 2.days.ago)
      create(:gift_card, merchant: merchant)

      get admin_gift_cards_path(filter: "disputed")

      expect(response.body).to include("REM-#{disputed.id.to_s.last(6)}")
      expect(response.body).to include("Disputadas (1)")
    end

    it "filters held cards" do
      merchant = create(:merchant)
      held = create(:gift_card, merchant: merchant, held_until: 2.hours.from_now, risk_score: 70)
      create(:gift_card, merchant: merchant)

      get admin_gift_cards_path(filter: "held")

      expect(response.body).to include("REM-#{held.id.to_s.last(6)}")
      expect(response.body).to include("Retenidas (1)")
    end

    it "searches by buyer email, merchant name, payment intent and REM ref" do
      merchant = create(:merchant, store_name: "Farmacias Sol")
      buyer = create(:user, email: "unico@example.com")
      card = create(:gift_card, sender: buyer, merchant: merchant, payment_intent_id: "pi_busca_123")
      other = create(:gift_card)

      get admin_gift_cards_path(q: "unico@example.com")
      expect(response.body).to include("REM-#{card.id.to_s.last(6)}")
      expect(response.body).not_to include("REM-#{other.id.to_s.last(6)}")

      get admin_gift_cards_path(q: "Farmacias Sol")
      expect(response.body).to include("REM-#{card.id.to_s.last(6)}")

      get admin_gift_cards_path(q: "pi_busca_123")
      expect(response.body).to include("REM-#{card.id.to_s.last(6)}")

      get admin_gift_cards_path(q: "REM-#{card.id}")
      expect(response.body).to include("REM-#{card.id.to_s.last(6)}")
    end

    it "survives garbage params" do
      get admin_gift_cards_path(filter: "bogus", page: -4, q: "'\"%_zz")

      expect(response).to have_http_status(:ok)
    end

    it "blocks non-admins" do
      sign_in create(:user)

      get admin_gift_cards_path

      expect(response).to redirect_to(root_path)
    end
  end

  describe "GET /admin/gift_cards/:id" do
    it "shows the card with parties, payment and ledger timeline" do
      merchant = create(:merchant, store_name: "Medicity")
      buyer = create(:user, first_name: "Sofía", last_name: "Paz")
      recipient = create(:user, first_name: "Rita", last_name: "Paz")
      card = create(:gift_card, sender: buyer, recipient: recipient, merchant: merchant,
                                amount: 5_000, payment_intent_id: "pi_show_1")
      card.transactions.create!(
        amount: 5_000, txn_type: :purchase, status: :succeeded,
        processor_ref: "pi_show_1", merchant: merchant, user: buyer, currency: "USD",
        metadata: { "subtotal_cents" => 5_000, "stripe_fee_cents" => 175 }
      )

      get admin_gift_card_path(card)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("REM-#{card.id.to_s.last(6)}")
      expect(response.body).to include("Sofía Paz", "Rita Paz", "Medicity")
      expect(response.body).to include("pi_show_1")
      expect(response.body).to include("Compra")
      expect(response.body).to include("Costo Stripe")
      expect(response.body).to include("Emitir reembolso")
    end

    it "labels a Stripe refund and a dispute write-off distinctly in the ledger" do
      card = create(:gift_card, amount: 3_000, payment_intent_id: "pi_refund_1", status: :canceled, remaining_balance: 0)
      card.transactions.create!(
        amount: 3_000, txn_type: :refund, status: :succeeded,
        processor_ref: "re_ledger_1", currency: "USD",
        metadata: { "stripe_refund_id" => "re_ledger_1", "previous_card_status" => "active", "source" => "stripe_webhook" }
      )
      card.transactions.create!(
        amount: 0, txn_type: :adjustment, status: :succeeded,
        processor_ref: "dispute_du_ledger_1", currency: "USD",
        metadata: { "stripe_dispute_id" => "du_ledger_1", "source" => "dispute_lost", "previous_card_status" => "active" }
      )

      get admin_gift_card_path(card)

      expect(response.body).to include("Reembolso Stripe al comprador")
      expect(response.body).to include("Disputa perdida — saldo anulado")
      expect(response.body).to include("Estado anterior de la tarjeta")
    end

    it "offers hold release only while the card is held" do
      held = create(:gift_card, held_until: 3.hours.from_now, risk_score: 70)

      get admin_gift_card_path(held)
      expect(response.body).to include("Liberar retención")

      released = create(:gift_card, held_until: 1.hour.ago, risk_score: 70)
      get admin_gift_card_path(released)
      expect(response.body).not_to include("Liberar retención")
      expect(response.body).to include("Estuvo retenida")
    end

    it "hides the refund action for non-Stripe or drained cards" do
      no_stripe = create(:gift_card, payment_intent_id: nil)
      get admin_gift_card_path(no_stripe)
      expect(response.body).not_to include("Emitir reembolso")
      expect(response.body).to include("Sin pago Stripe")

      drained = create(:gift_card, payment_intent_id: "pi_drained_1", status: :canceled, remaining_balance: 0)
      get admin_gift_card_path(drained)
      expect(response.body).not_to include("Emitir reembolso")
    end
  end

  describe "releasing a hold from the card page" do
    it "releases and redirects back to the card" do
      card = create(:gift_card, held_until: 3.hours.from_now, risk_score: 70)

      post release_admin_hold_path(card), params: { reason: "Comprador verificado" },
                                          headers: { "HTTP_REFERER" => admin_gift_card_path(card) }

      expect(response).to redirect_to(admin_gift_card_path(card))
      expect(card.reload.held?).to be(false)
    end
  end

  describe "web wallet scope" do
    it "no longer shows other people's cards to admins" do
      create(:gift_card) # someone else's card
      mine = create(:gift_card, sender: admin)

      get gift_cards_path(format: :json)

      data = JSON.parse(response.body)
      expect(data.map { |c| c["id"] }).to eq([mine.id])
    end
  end
end
