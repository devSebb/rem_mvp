require "rails_helper"

RSpec.describe GiftCards::ClaimLink do
  let(:gift_card) { create(:gift_card) }

  describe ".issue!" do
    it "returns a token and persists digest + expiry" do
      token = described_class.issue!(gift_card)

      expect(token).to be_present
      expect(token.length).to eq(described_class::TOKEN_LENGTH)
      expect(gift_card.reload.link_token_digest).to eq(Digest::SHA256.hexdigest(token))
      expect(gift_card.link_token_expires_at).to be_within(1.minute).of(described_class::TTL.from_now)
    end

    it "returns the same token across re-issues (stable per card)" do
      expect(described_class.issue!(gift_card)).to eq(described_class.issue!(gift_card))
    end

    it "refreshes the expiry on re-issue (sliding TTL)" do
      described_class.issue!(gift_card)
      gift_card.update_columns(link_token_expires_at: 1.day.from_now)

      described_class.issue!(gift_card)

      expect(gift_card.reload.link_token_expires_at).to be_within(1.minute).of(described_class::TTL.from_now)
    end

    it "does not bump updated_at (wallet sort order)" do
      original = gift_card.updated_at

      described_class.issue!(gift_card)

      expect(gift_card.reload.updated_at).to be_within(1.second).of(original)
    end
  end

  describe ".find_by_token" do
    it "returns the gift card for a valid token" do
      token = described_class.issue!(gift_card)

      expect(described_class.find_by_token(token)).to eq(gift_card)
    end

    it "returns nil for an unknown token" do
      expect(described_class.find_by_token("nope")).to be_nil
    end

    it "returns nil for a blank token" do
      expect(described_class.find_by_token(nil)).to be_nil
      expect(described_class.find_by_token("")).to be_nil
    end

    it "returns nil once the link has expired" do
      token = described_class.issue!(gift_card)
      gift_card.update_columns(link_token_expires_at: 1.minute.ago)

      expect(described_class.find_by_token(token)).to be_nil
    end
  end

  describe ".revoke!" do
    it "invalidates the link" do
      token = described_class.issue!(gift_card)

      described_class.revoke!(gift_card)

      expect(described_class.find_by_token(token)).to be_nil
      expect(gift_card.reload.link_token_digest).to be_nil
    end

    it "re-issuing after revoke restores the same (HMAC-derived) token" do
      token = described_class.issue!(gift_card)
      described_class.revoke!(gift_card)

      expect(described_class.issue!(gift_card)).to eq(token)
    end
  end

  describe ".url_for" do
    it "builds the claim URL and persists the link" do
      url = described_class.url_for(gift_card)

      token = url.split("/claim/").last
      expect(url).to eq(AppLinks.claim_url(token))
      expect(described_class.find_by_token(token)).to eq(gift_card)
    end
  end
end
