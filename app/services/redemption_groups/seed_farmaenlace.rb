# Seeds the "Farmaenlace" redemption group and assigns the seven merchants
# that existed in production when redemption groups were introduced
# (RELOADABLE_CARD_PLAN.md §3.7, §5.6 — membership locked 2026-09-12).
#
# Used by the Phase 2 migration and by db/seeds.rb. Idempotent: the group is
# found-or-created, already-assigned merchants are left alone. Members are
# resolved by store_name with an id fallback; if any of the seven cannot be
# found the whole call raises so the migration cannot half-apply (§16.5).
# Merchants onboarded after this get no group unless an admin assigns one.
module RedemptionGroups
  module SeedFarmaenlace
    class MissingMerchant < StandardError; end

    GROUP_NAME = "Farmaenlace".freeze

    # [prod id, store_name] — from the prod query in §5.6.
    MEMBERS = [
      [1, "Mascotas"],
      [2, "Farmacias Económicas"],
      [3, "Movistar"],
      [4, "Medicity"],
      [5, "Tuenti"],
      [6, "Salud S.A."],
      [7, "CNT"]
    ].freeze

    module_function

    # @return [Hash] { group:, assigned: [ids], already: [ids], by_id_fallback: [names] }
    #   or { skipped: reason } on a database with no merchants at all.
    def call
      return { skipped: "no merchants in this database (fresh install)" } unless Merchant.exists?

      resolved, missing, by_id = resolve_members
      if missing.any?
        raise MissingMerchant,
              "Farmaenlace group seed: cannot find merchant(s) #{missing.inspect} by store_name or id; " \
              "nothing was assigned (#{Merchant.count} merchants present: " \
              "#{Merchant.order(:id).pluck(:id, :store_name).inspect})"
      end

      group = RedemptionGroup.find_or_create_by!(name: GROUP_NAME)
      assigned = []
      already = []
      RedemptionGroup.transaction do
        resolved.each do |merchant|
          if merchant.redemption_group_id == group.id
            already << merchant.id
          elsif merchant.redemption_group_id.nil?
            merchant.update_columns(redemption_group_id: group.id, updated_at: Time.current)
            assigned << merchant.id
          else
            raise MissingMerchant,
                  "merchant #{merchant.id} (#{merchant.store_name}) already belongs to another redemption group " \
                  "(#{merchant.redemption_group_id}); refusing to move it"
          end
        end
      end

      { group: group, assigned: assigned, already: already, by_id_fallback: by_id }
    end

    def resolve_members
      resolved = []
      missing = []
      by_id = []
      MEMBERS.each do |id, name|
        merchant = Merchant.find_by(store_name: name)
        if merchant.nil? && (candidate = Merchant.find_by(id: id))
          merchant = candidate
          by_id << name
        end
        merchant ? resolved << merchant : missing << name
      end
      [resolved.uniq, missing, by_id]
    end
  end
end
