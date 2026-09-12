require 'rails_helper'

# §5.9 receipt mailer per load: first card vs reload vs self subjects.
RSpec.describe PurchaseConfirmationMailer, type: :mailer do
  def bodies_of(mail)
    return mail.parts.map { |part| part.body.to_s } if mail.multipart?

    [mail.body.to_s]
  end

  let(:merchant) { create(:merchant, store_name: "Medicity") }
  let(:buyer) { create(:user, first_name: "Ana", email: "ana@example.com") }
  let(:recipient) { create(:user, first_name: "Rita", last_name: "Paz") }
  let(:card) { create(:gift_card, recipient: recipient, merchant: merchant, amount: 0) }

  describe "#receipt" do
    it "names the merchant by its current store name after a rename" do
      merchant.update!(store_name: "Farmacia Buendía")
      load = stripe_load!(card, 3_000, sender: buyer)
      merchant.update!(store_name: "Medicity")

      bodies = bodies_of(described_class.receipt(load.id))

      expect(bodies).not_to be_empty
      bodies.each do |body|
        expect(body).to include("Medicity")
        expect(body).not_to include("Buendía")
      end
    end

    it "uses the first-card subject and copy for the first load" do
      load = stripe_load!(card, 3_000, sender: buyer)
      mail = described_class.receipt(load.id)

      expect(mail.to).to eq(["ana@example.com"])
      expect(mail.subject).to eq("Tu tarjeta de regalo digital de Medicity para Rita Paz")
      bodies_of(mail).each { |b| expect(b).to include("recibirá una tarjeta de regalo digital de Medicity con $30.00").and include("Rita Paz") }
    end

    it "uses the reload subject for a later load and the self subject for a self-load" do
      stripe_load!(card, 3_000, sender: buyer, at: 1.day.ago)
      reload = stripe_load!(card, 2_000, sender: buyer)
      expect(described_class.receipt(reload.id).subject).to eq("Tu recarga de $20.00 para Rita Paz en Medicity")

      recipient.update!(email: "rita@example.com")
      own = stripe_load!(card, 1_000, sender: recipient)
      mail = described_class.receipt(own.id)
      expect(mail.subject).to eq("Tu recarga de $10.00 en Medicity")
      bodies_of(mail).each { |b| expect(b).to include("ya tiene $10.00 más") }
    end

    it "skips delivery when the buyer only has a placeholder email" do
      sender = create(:user, email: "#{User::CLAIM_EMAIL_PREFIX}abc@#{User::CLAIM_EMAIL_DOMAIN}")
      load = stripe_load!(card, 3_000, sender: sender)

      expect(described_class.receipt(load.id).to).to be_nil
    end
  end
end

RSpec.describe GiftCardMailer, type: :mailer do
  let(:merchant) { create(:merchant, store_name: "Medicity") }
  let(:buyer) { create(:user, first_name: "Ana") }
  let(:recipient) { create(:user, first_name: "Rita", email: "rita@example.com") }
  let(:card) { create(:gift_card, recipient: recipient, merchant: merchant, amount: 0) }

  it "announces the digital gift card on the first load with that load's claim link" do
    load = stripe_load!(card, 3_000, sender: buyer, note: "Feliz cumple")
    mail = described_class.deliver_gift_card(load)

    expect(mail.to).to eq(["rita@example.com"])
    expect(mail.subject).to eq("🎁 Recibiste una tarjeta de regalo digital de Medicity")
    token = GiftCards::ClaimLink.issue!(load)
    mail.parts.each do |part|
      expect(part.body.to_s).to include("$30.00").and include("Feliz cumple").and include(AppLinks.claim_url(token)).and include("Mis tarjetas")
    end
    expect(GiftCards::ClaimLink.find_by_token(token)).to eq(load)
  end

  it "announces a reload with the spendable balance" do
    stripe_load!(card, 3_000, sender: buyer, at: 1.day.ago)
    reload = stripe_load!(card, 2_000, sender: buyer)
    mail = described_class.deliver_gift_card(reload.id)

    expect(mail.subject).to eq("Ana recargó tu tarjeta de Medicity con $20.00")
    mail.parts.each { |part| expect(part.body.to_s).to include("Saldo disponible: $50.00") }
  end
end

RSpec.describe GiftCardHoldMailer, type: :mailer do
  it "tells the buyer only this load is held" do
    merchant = create(:merchant, store_name: "Medicity")
    buyer = create(:user, email: "buyer@example.com")
    card = create(:gift_card, merchant: merchant, amount: 0)
    load = stripe_load!(card, 2_500, sender: buyer, held_until: 20.hours.from_now)

    mail = described_class.held(load.id)

    expect(mail.to).to eq(["buyer@example.com"])
    expect(mail.subject).to eq("Tu recarga está bajo revisión de seguridad")
    mail.parts.each { |part| expect(part.body.to_s).to include("$25.00").and include("Solo esta recarga") }
  end
end
