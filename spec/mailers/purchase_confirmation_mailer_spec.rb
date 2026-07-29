require 'rails_helper'

RSpec.describe PurchaseConfirmationMailer, type: :mailer do
  # Every part of a multipart mail, or the single body when it isn't multipart.
  def bodies_of(mail)
    return mail.parts.map { |part| part.body.to_s } if mail.multipart?

    [mail.body.to_s]
  end

  describe "#receipt" do
    it "names the merchant by its current store name after a rename" do
      merchant = create(:merchant, store_name: "Farmacia Buendía")
      merchant.update!(store_name: "Medicity")
      gift_card = create(:gift_card, merchant: merchant)

      bodies = bodies_of(described_class.receipt(gift_card.id))

      expect(bodies).not_to be_empty
      bodies.each do |body|
        expect(body).to include("Medicity")
        expect(body).not_to include("Buendía")
      end
    end

    it "skips delivery when the buyer only has a placeholder email" do
      sender = create(:user, email: "#{User::CLAIM_EMAIL_PREFIX}abc@#{User::CLAIM_EMAIL_DOMAIN}")
      gift_card = create(:gift_card, sender: sender)

      expect(described_class.receipt(gift_card.id).to).to be_nil
    end
  end
end
