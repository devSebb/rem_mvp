require "rails_helper"

# §5.9: claim links are per LOAD; pre-Phase-3 card-level links keep working.
RSpec.describe GiftCards::ClaimLink do
  let(:gift_card) { create(:gift_card, amount: 0) }
  let(:load) { stripe_load!(gift_card, 2_500, sender: create(:user)) }

  describe ".issue!" do
    it "returns a token and persists digest + expiry on the load" do
      token = described_class.issue!(load)

      expect(token).to be_present
      expect(token.length).to eq(described_class::TOKEN_LENGTH)
      expect(load.reload.link_token_digest).to eq(Digest::SHA256.hexdigest(token))
      expect(load.link_token_expires_at).to be_within(1.minute).of(described_class::TTL.from_now)
      expect(gift_card.reload.link_token_digest).to be_nil
    end

    it "returns the same token across re-issues (stable per load) and differs between loads" do
      other = stripe_load!(gift_card, 1_000, sender: create(:user))
      expect(described_class.issue!(load)).to eq(described_class.issue!(load))
      expect(described_class.issue!(load)).not_to eq(described_class.issue!(other))
    end

    it "refreshes the expiry on re-issue (sliding TTL)" do
      described_class.issue!(load)
      load.update_columns(link_token_expires_at: 1.day.from_now)

      described_class.issue!(load)

      expect(load.reload.link_token_expires_at).to be_within(1.minute).of(described_class::TTL.from_now)
    end
  end

  describe ".find_by_token" do
    it "returns the load for a valid token" do
      token = described_class.issue!(load)

      expect(described_class.find_by_token(token)).to eq(load)
    end

    it "returns nil for an unknown or blank token" do
      expect(described_class.find_by_token("nope")).to be_nil
      expect(described_class.find_by_token(nil)).to be_nil
      expect(described_class.find_by_token("")).to be_nil
    end

    it "returns nil once the link has expired" do
      token = described_class.issue!(load)
      load.update_columns(link_token_expires_at: 1.minute.ago)

      expect(described_class.find_by_token(token)).to be_nil
    end

    it "resolves a legacy card-level link to the card's first load until it expires" do
      load # first load
      later = stripe_load!(gift_card, 500, sender: create(:user))
      legacy_token = OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base,
                                             "#{described_class::LEGACY_HMAC_PURPOSE}:#{gift_card.id}")[0, 32]
      gift_card.update_columns(link_token_digest: Digest::SHA256.hexdigest(legacy_token), link_token_expires_at: 10.days.from_now)

      expect(described_class.find_by_token(legacy_token)).to eq(load)
      expect(described_class.find_by_token(legacy_token)).not_to eq(later)

      gift_card.update_columns(link_token_expires_at: 1.minute.ago)
      expect(described_class.find_by_token(legacy_token)).to be_nil
    end

    it "never lets a legacy card token open a load with the same numeric id" do
      legacy_token = OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base,
                                             "#{described_class::LEGACY_HMAC_PURPOSE}:#{load.id}")[0, 32]
      expect(described_class.issue!(load)).not_to eq(legacy_token)
    end
  end

  describe ".revoke!" do
    it "invalidates the link and re-issue restores the same token" do
      token = described_class.issue!(load)

      described_class.revoke!(load)

      expect(described_class.find_by_token(token)).to be_nil
      expect(load.reload.link_token_digest).to be_nil
      expect(described_class.issue!(load)).to eq(token)
    end
  end

  describe ".url_for" do
    it "builds the claim URL and persists the link" do
      url = described_class.url_for(load)

      token = url.split("/claim/").last
      expect(url).to eq(AppLinks.claim_url(token))
      expect(described_class.find_by_token(token)).to eq(load)
    end
  end
end
