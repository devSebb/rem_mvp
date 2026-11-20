require "rails_helper"
require "ostruct"

# Money-path bugs found in the Nov 2026 audit.
RSpec.describe "Money fixes", type: :request do
  include Devise::Test::IntegrationHelpers
  include ActiveSupport::Testing::TimeHelpers

  let(:admin) { create(:user, role: :admin) }

  # ── Payouts: same-day redemptions after a payout must not be lost ────────

  describe "payout cutoff" do
    let(:merchant) { create(:merchant) }

    def redemption!(cents, at:)
      card = create(:gift_card, merchant: merchant, amount: cents)
      Transaction.create!(gift_card: card, merchant: merchant, amount: cents, txn_type: :redemption,
                          status: :succeeded, processor_ref: "red_#{SecureRandom.hex(6)}", currency: "USD",
                          metadata: {}, created_at: at)
    end

    it "pays a redemption made later on the same day in the NEXT payout" do
      sign_in admin
      day = Time.utc(2026, 11, 20)

      redemption!(10_000, at: day.change(hour: 9))
      travel_to(day.change(hour: 10)) { post admin_payouts_path(merchant_id: merchant.id) }
      first = Settlement.last
      expect(first.amount).to eq(10_000)
      expect(first.period_end_at).to eq(day.change(hour: 10))

      late = redemption!(2_500, at: day.change(hour: 15)) # after the 10:00 payout, same day

      # Before the fix this was inside the first payout's "end of day" window:
      # not in its amount, and excluded from every later payout.
      expect(merchant.unsettled_redemptions).to contain_exactly(late)
      expect(first.transactions).not_to include(late)
      expect(first.amount_matches_calculated?).to be(true)

      travel_to(day.change(hour: 18)) { post admin_payouts_path(merchant_id: merchant.id) }
      second = Settlement.last
      expect(second).not_to eq(first)
      expect(second.amount).to eq(2_500)
      expect(merchant.reload.unsettled_redemptions).to be_empty # reload: settlements association was cached
    end

    it "keeps redemptions committed after the cutoff out of the payout being created" do
      sign_in admin
      cutoff = Time.utc(2026, 11, 20, 10)
      redemption!(1_000, at: cutoff - 1.minute)
      redemption!(4_000, at: cutoff + 1.minute) # e.g. committed while the payout was being created

      travel_to(cutoff) { post admin_payouts_path(merchant_id: merchant.id) }

      expect(Settlement.last.amount).to eq(1_000)
      expect(merchant.unsettled_redemptions.sum(:amount)).to eq(4_000)
    end
  end

  # ── Merchant web redemption: exact cents ─────────────────────────────────

  describe "merchant redemption amount" do
    let(:merchant_user) { create(:user, role: :merchant) }
    let!(:merchant) { create(:merchant, user: merchant_user) }
    let!(:card) { create(:gift_card, merchant: merchant, amount: 5_000, remaining_balance: 5_000, status: :active) }

    before do
      sign_in merchant_user
      allow(Messaging::RedemptionPusher).to receive(:call)
    end

    def redeem(amount)
      token = RedemptionTokens::Issue.call(gift_card: card)[:token]
      post redeem_merchant_redemptions_path, params: {
        gift_card_id: card.id, redemption_amount: amount, idempotency_token: SecureRandom.uuid, redemption_token: token
      }
    end

    it "captures $19.99 as 1999 cents (was 1998)" do
      redeem("19.99")
      expect(Transaction.redemptions.successful.last.amount).to eq(1_999)
      expect(card.reload.remaining_balance).to eq(5_000 - 1_999)
    end

    it "rejects an unparseable amount without capturing anything" do
      expect { redeem("19.999") }.not_to change(Transaction, :count)
      expect(flash[:alert]).to include("monto válido")
    end
  end

  # ── Admin Stripe refunds ─────────────────────────────────────────────────

  describe "admin Stripe refund" do
    let(:card) { create(:gift_card, amount: 0) }
    let!(:load) { stripe_load!(card, 5_000, sender: create(:user), payment_intent_id: "pi_money_fix") }

    before do
      sign_in admin
      allow(AdminAlertMailer).to receive(:over_refund).and_return(double(deliver_later: true))
    end

    def stripe_refund(id:, amount:, status: "succeeded")
      OpenStruct.new(id: id, amount: amount, currency: "usd", status: status, payment_intent: "pi_money_fix",
                     charge: "ch_x", reason: "requested_by_customer")
    end

    it "sends exact cents to Stripe and debits the card immediately, before the webhook" do
      expect(Stripe::Refund).to receive(:create)
        .with(hash_including(amount: 1_999), anything)
        .and_return(stripe_refund(id: "re_now", amount: 1_999))

      post admin_gift_card_load_refund_path(card, load), params: { refund_amount: "19.99", reason: "pedido del cliente" }

      # Spendable is reduced right away: no window to spend refunded money.
      expect(card.reload.balances[:spendable_cents]).to eq(5_000 - 1_999)
      expect(Transaction.refunds.where(processor_ref: "re_now").sole.metadata["source"]).to eq("admin_refund")

      # The webhook arriving later is a no-op (no double debit).
      StripeWebhooks.handle_refund_event(stripe_refund(id: "re_now", amount: 1_999))
      expect(card.reload.balances[:spendable_cents]).to eq(5_000 - 1_999)
      expect(Transaction.refunds.where(processor_ref: "re_now").count).to eq(1)
    end

    it "gives two separate same-amount refund forms distinct Stripe idempotency keys" do
      keys = []
      allow(Stripe::Refund).to receive(:create) do |params, opts|
        keys << opts[:idempotency_key]
        stripe_refund(id: "re_#{keys.size}", amount: params[:amount])
      end

      2.times do
        get new_admin_gift_card_load_refund_path(card, load)
        token = response.body[/name="idempotency_token"[^>]*value="([^"]+)"/, 1] ||
                response.body[/value="([^"]+)"[^>]*name="idempotency_token"/, 1]
        expect(token).to be_present
        post admin_gift_card_load_refund_path(card, load),
             params: { refund_amount: "5.00", reason: "parcial", idempotency_token: token }
      end

      expect(keys.uniq.size).to eq(2)
      expect(card.reload.balances[:spendable_cents]).to eq(5_000 - 1_000)
    end
  end
end
