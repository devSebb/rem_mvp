require "rails_helper"

# Farmaenlace group seed (RELOADABLE_CARD_PLAN.md §3.7, §5.6) as run by the
# Phase 2 migration and db/seeds.rb.
RSpec.describe RedemptionGroups::SeedFarmaenlace do
  let(:names) { described_class::MEMBERS.map(&:last) }

  def create_launch_merchants(except: [])
    names.reject { |n| except.include?(n) }.map { |n| create(:merchant, store_name: n) }
  end

  it "creates the group and assigns exactly the seven launch merchants" do
    launch = create_launch_merchants
    later = create(:merchant, store_name: "Nueva Tienda")

    result = described_class.call
    group = RedemptionGroup.find_by!(name: "Farmaenlace")
    expect(result[:group]).to eq(group)
    expect(result[:assigned]).to match_array(launch.map(&:id))
    expect(result[:by_id_fallback]).to be_empty
    expect(launch.map { |m| m.reload.redemption_group }).to all(eq(group))
    expect(later.reload.redemption_group).to be_nil
  end

  it "is idempotent" do
    create_launch_merchants
    described_class.call
    result = described_class.call
    expect(result[:assigned]).to be_empty
    expect(result[:already].size).to eq(7)
    expect(RedemptionGroup.where(name: "Farmaenlace").count).to eq(1)
  end

  it "raises naming the missing merchants and assigns nothing (§16.5 stop condition)" do
    create_launch_merchants(except: ["Tuenti", "CNT"])

    expect { described_class.call }.to raise_error(described_class::MissingMerchant, /\["Tuenti", "CNT"\]/)
    expect(RedemptionGroup.where(name: "Farmaenlace")).not_to exist
    expect(Merchant.where.not(redemption_group_id: nil)).not_to exist
  end

  it "falls back to the production id when the name was changed" do
    create_launch_merchants(except: ["Movistar"])
    renamed = create(:merchant, store_name: "Movistar Ecuador")
    renamed.update_columns(id: 3) unless Merchant.exists?(3)

    result = described_class.call
    expect(result[:by_id_fallback]).to eq(["Movistar"])
    expect(Merchant.find(3).redemption_group).to eq(result[:group])
  end

  it "skips on a database with no merchants" do
    expect(described_class.call[:skipped]).to match(/no merchants/)
    expect(RedemptionGroup.count).to eq(0)
  end

  it "refuses to move a launch merchant that already sits in another group" do
    launch = create_launch_merchants
    launch.first.update!(redemption_group: create(:redemption_group, name: "Otro"))

    expect { described_class.call }.to raise_error(described_class::MissingMerchant, /another redemption group/)
  end
end
