require "rails_helper"

# §5.10: scope = recipient OR any load's sender; per-load policy for sharing.
RSpec.describe GiftCardPolicy do
  let(:recipient) { create(:user) }
  let(:first_buyer) { create(:user) }
  let(:second_buyer) { create(:user) }
  let(:stranger) { create(:user) }
  let(:admin) { create(:user, role: :admin) }
  let(:card) { create(:gift_card, recipient: recipient, amount: 0) }

  before do
    stripe_load!(card, 1_000, sender: first_buyer, at: 2.days.ago)
    stripe_load!(card, 1_000, sender: second_buyer, at: 1.day.ago)
  end

  it "scopes cards to the recipient and every buyer, ignoring the deprecated sender_id" do
    card.update_columns(sender_id: stranger.id) # deprecated column must not grant access
    expect(GiftCardPolicy::Scope.new(recipient, GiftCard).resolve).to eq([card])
    expect(GiftCardPolicy::Scope.new(first_buyer, GiftCard).resolve).to eq([card])
    expect(GiftCardPolicy::Scope.new(second_buyer, GiftCard).resolve).to eq([card])
    expect(GiftCardPolicy::Scope.new(stranger, GiftCard).resolve).to be_empty
    expect(GiftCardPolicy::Scope.new(admin, GiftCard).resolve).to be_empty # wallet semantics
  end

  it "show? / view_code? / share? follow the same rules" do
    expect(described_class.new(second_buyer, card).show?).to be(true)
    expect(described_class.new(stranger, card).show?).to be(false)
    expect(described_class.new(second_buyer, card).view_code?).to be(false)
    expect(described_class.new(recipient, card).view_code?).to be(true)
    expect(described_class.new(second_buyer, card).share?).to be(true)
    expect(described_class.new(recipient, card).share?).to be(false)
    expect(described_class.new(admin, card).freeze?).to be(true)
    expect(described_class.new(recipient, card).freeze?).to be(false)
    expect(described_class.new(recipient, card)).not_to respond_to(:transfer?)
  end

  describe GiftCardLoadPolicy do
    it "lets only the load's sender share/resend, and the recipient or sender see it" do
      load = card.loads.fifo.first
      expect(GiftCardLoadPolicy.new(first_buyer, load).share?).to be(true)
      expect(GiftCardLoadPolicy.new(second_buyer, load).share?).to be(false)
      expect(GiftCardLoadPolicy.new(recipient, load).share?).to be(false)
      expect(GiftCardLoadPolicy.new(recipient, load).show?).to be(true)
      expect(GiftCardLoadPolicy.new(stranger, load).show?).to be(false)
      expect(GiftCardLoadPolicy.new(admin, load).release_hold?).to be(true)
      expect(GiftCardLoadPolicy::Scope.new(first_buyer, GiftCardLoad).resolve).to eq([load])
      expect(GiftCardLoadPolicy::Scope.new(recipient, GiftCardLoad).resolve.count).to eq(2)
    end
  end
end
