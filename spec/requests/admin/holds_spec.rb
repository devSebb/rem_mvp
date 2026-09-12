require "rails_helper"

# §9: the holds page lists LOADS and releases per load.
RSpec.describe "Admin::Holds", type: :request do
  let(:admin) { create(:user, role: :admin) }

  before { sign_in admin }

  it "lists held loads soonest-first with their card, buyer and amount" do
    card = create(:gift_card, amount: 0)
    later = stripe_load!(card, 2_000, sender: create(:user, first_name: "Bea"), held_until: 5.hours.from_now, risk_score: 70)
    sooner = stripe_load!(card, 1_500, sender: create(:user, first_name: "Al"), held_until: 1.hour.from_now, risk_score: 66)
    stripe_load!(card, 500, sender: create(:user)) # not held

    get admin_holds_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Recargas retenidas")
    expect(response.body).to include("$20.00", "$15.00", "Bea", "Al")
    expect(response.body.index("##{sooner.id}")).to be < response.body.index("##{later.id}")
    expect(response.body).to include(release_admin_hold_path(sooner), release_admin_hold_path(later))
  end

  it "requires a reason and refuses to release a load that is not held" do
    card = create(:gift_card, amount: 0)
    held = stripe_load!(card, 2_000, sender: create(:user), held_until: 5.hours.from_now)

    post release_admin_hold_path(held), params: { reason: "" }
    expect(flash[:alert]).to include("razón")
    expect(held.reload.held?).to be(true)

    free = stripe_load!(card, 500, sender: create(:user))
    post release_admin_hold_path(free), params: { reason: "x" }
    expect(flash[:alert]).to include("no está bajo bloqueo")
  end

  it "pushes the recipient when a hold is released" do
    pusher = instance_double(Messaging::PushSender, send_to_user: { success: true })
    allow(Messaging::PushSender).to receive(:new).and_return(pusher)
    recipient = create(:user)
    card = create(:gift_card, recipient: recipient, merchant: create(:merchant, store_name: "Medicity"), amount: 0)
    held = stripe_load!(card, 2_000, sender: create(:user), held_until: 5.hours.from_now)

    post release_admin_hold_path(held), params: { reason: "verificado" }

    expect(pusher).to have_received(:send_to_user).with(
      recipient,
      title: "Tu saldo ya está disponible",
      body: "$20.00 en Medicity pasaron la revisión de seguridad.",
      data: { type: "gift_card_hold_released", gift_card_id: card.id.to_s, load_id: held.id.to_s }
    )
  end

  it "blocks non-admins" do
    sign_in create(:user)
    get admin_holds_path
    expect(response).to redirect_to(root_path)
  end
end
