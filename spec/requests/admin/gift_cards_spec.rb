require "rails_helper"

# §9 admin card browser: filters, load-aware search, per-load hold release,
# card actions (freeze/unfreeze/cancel at zero balance).
RSpec.describe "Admin::GiftCards", type: :request do
  let(:admin) { create(:user, role: :admin) }

  before { sign_in admin }

  describe "GET /admin/gift_cards" do
    it "lists every card with recipient, merchant, spendable/total and loads count" do
      merchant = create(:merchant, store_name: "Luccianos")
      buyer = create(:user, first_name: "Bruno", last_name: "Comprador")
      holder = create(:user, first_name: "Rita", last_name: "Titular")
      card = create(:gift_card, recipient: holder, merchant: merchant, amount: 0)
      stripe_load!(card, 3_000, sender: buyer)
      stripe_load!(card, 2_000, sender: buyer, held_until: 2.hours.from_now)

      get admin_gift_cards_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Luccianos", "Rita Titular")
      expect(response.body).to include("$30.00") # spendable
      expect(response.body).to include("$50.00") # total
      expect(response.body).to include("Retenido $20.00")
    end

    it "filters cards with an open dispute, a hold, frozen and zero balance" do
      merchant = create(:merchant)
      disputed = create(:gift_card, merchant: merchant, amount: 0)
      stripe_load!(disputed, 1_000, sender: create(:user), disputed_at: 2.days.ago)
      held = create(:gift_card, merchant: merchant, amount: 0)
      stripe_load!(held, 1_000, sender: create(:user), held_until: 2.hours.from_now)
      frozen = create(:gift_card, merchant: merchant, status: :frozen_by_admin)
      drained = create(:gift_card, merchant: merchant, amount: 0)
      create(:gift_card, merchant: merchant)

      get admin_gift_cards_path(filter: "with_disputed")
      expect(response.body).to include("REM-#{disputed.id.to_s.last(6)}")
      expect(response.body).to include("En disputa (1)")
      expect(response.body).not_to include("REM-#{held.id.to_s.last(6)}")

      get admin_gift_cards_path(filter: "with_held")
      expect(response.body).to include("REM-#{held.id.to_s.last(6)}")
      expect(response.body).to include("Con retención (1)")

      get admin_gift_cards_path(filter: "frozen")
      expect(response.body).to include("REM-#{frozen.id.to_s.last(6)}")
      expect(response.body).to include("Congeladas (1)")

      get admin_gift_cards_path(filter: "zero_balance")
      expect(response.body).to include("REM-#{drained.id.to_s.last(6)}")

      get admin_gift_cards_path(filter: "held") # old link alias
      expect(response.body).to include("REM-#{held.id.to_s.last(6)}")
    end

    it "searches by any load's buyer email or payment intent, merchant name and REM ref" do
      merchant = create(:merchant, store_name: "Farmacias Sol")
      buyer = create(:user, email: "unico@example.com")
      card = create(:gift_card, merchant: merchant, amount: 0)
      stripe_load!(card, 1_000, sender: create(:user), payment_intent_id: "pi_first")
      stripe_load!(card, 1_000, sender: buyer, payment_intent_id: "pi_busca_123") # not the first sender
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
    it "shows tiles, the Recargas table, parties and the ledger with allocation breakdown" do
      merchant = create(:merchant, store_name: "Medicity")
      buyer = create(:user, first_name: "Sofía", last_name: "Paz")
      recipient = create(:user, first_name: "Rita", last_name: "Paz")
      card = create(:gift_card, recipient: recipient, merchant: merchant, amount: 0)
      a = stripe_load!(card, 500, sender: buyer, payment_intent_id: "pi_show_1", at: 2.days.ago)
      b = stripe_load!(card, 3_000, sender: create(:user, first_name: "Luis"), payment_intent_id: "pi_show_2", at: 1.day.ago)
      redeem_card!(card, 2_000, merchant: merchant)

      get admin_gift_card_path(card)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("REM-#{card.id.to_s.last(6)}")
      expect(response.body).to include("Sofía Paz", "Rita Paz", "Medicity", "Luis")
      expect(response.body).to include("pi_show_1".last(10), "pi_show_2".last(10))
      expect(response.body).to include("Recargas")
      expect(response.body).to include("Canjeado neto")
      expect(response.body).to include("recarga ##{a.id}", "recarga ##{b.id}") # allocation chips
      expect(response.body).to include("−$5.00 · recarga ##{a.id}", "−$15.00 · recarga ##{b.id}")
      expect(response.body).to include("Emitir reembolso")
      expect(response.body).to include("Congelar")
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

    it "offers hold release per load only while that load is held" do
      card = create(:gift_card, amount: 0)
      stripe_load!(card, 1_000, sender: create(:user))
      held = stripe_load!(card, 2_000, sender: create(:user), held_until: 3.hours.from_now, risk_score: 70)

      get admin_gift_card_path(card)
      expect(response.body).to include("Liberar retención")
      expect(response.body).to include(release_admin_hold_path(held))

      held.update_columns(held_until: 1.hour.ago)
      get admin_gift_card_path(card)
      expect(response.body).not_to include("Liberar retención")
      expect(response.body).to include("Retención terminó")
    end

    it "hides the refund action for non-Stripe or drained cards" do
      no_stripe = create(:gift_card, payment_intent_id: nil)
      get admin_gift_card_path(no_stripe)
      expect(response.body).not_to include("Emitir reembolso")

      drained = create(:gift_card, payment_intent_id: "pi_drained_1", status: :canceled, remaining_balance: 0)
      get admin_gift_card_path(drained)
      expect(response.body).not_to include("Emitir reembolso")
    end
  end

  describe "releasing a hold from the card page (per load)" do
    it "releases only that load and redirects back to the card" do
      card = create(:gift_card, amount: 0)
      held = stripe_load!(card, 2_000, sender: create(:user), held_until: 3.hours.from_now)
      other = stripe_load!(card, 1_000, sender: create(:user), held_until: 3.hours.from_now)

      post release_admin_hold_path(held), params: { reason: "Comprador verificado" },
                                          headers: { "HTTP_REFERER" => admin_gift_card_path(card) }

      expect(response).to redirect_to(admin_gift_card_path(card))
      expect(held.reload.held?).to be(false)
      expect(held.hold_released_by).to eq(admin)
      expect(other.reload.held?).to be(true)
      expect(card.reload.balances).to include(spendable_cents: 2_000, held_cents: 1_000)
    end
  end

  describe "card actions (§5.8)" do
    let(:card) { create(:gift_card, amount: 0) }

    it "freezes with a reason, refuses redemptions while frozen, and unfreezes" do
      stripe_load!(card, 1_000, sender: create(:user))

      patch freeze_admin_gift_card_path(card), params: { reason: "Fraude confirmado" }
      expect(response).to redirect_to(admin_gift_card_path(card))
      expect(card.reload).to be_frozen_by_admin
      expect(card.frozen_reason).to eq("Fraude confirmado")
      expect(card.frozen_at).to be_present
      expect(card.spendable_cents).to eq(0)
      expect(card.remaining_balance).to eq(1_000) # money untouched

      patch freeze_admin_gift_card_path(card), params: { reason: "" }
      expect(flash[:alert]).to include("motivo")

      patch unfreeze_admin_gift_card_path(card)
      expect(card.reload).to be_active
      expect(card.spendable_cents).to eq(1_000)
    end

    it "cancels only at zero balance" do
      stripe_load!(card, 1_000, sender: create(:user))

      patch cancel_admin_gift_card_path(card), params: { reason: "Cuenta duplicada" }
      expect(card.reload).to be_active
      expect(flash[:alert]).to include("saldo cero")

      redeem_card!(card, 1_000, merchant: card.merchant)
      patch cancel_admin_gift_card_path(card), params: { reason: "Cuenta duplicada" }
      expect(card.reload).to be_canceled
      expect(card.verify_ledger!).to be(true)
    end
  end

  describe "web wallet scope" do
    it "shows a card to every buyer who loaded it, never to strangers" do
      create(:gift_card) # someone else's card
      mine = create(:gift_card, amount: 0)
      stripe_load!(mine, 500, sender: create(:user))
      stripe_load!(mine, 500, sender: admin) # admin is the SECOND buyer

      get gift_cards_path(format: :json)

      data = JSON.parse(response.body)
      expect(data.map { |c| c["id"] }).to eq([mine.id])
    end
  end
end
