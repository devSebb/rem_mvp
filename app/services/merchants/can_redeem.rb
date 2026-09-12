# D6 / §3.7: a merchant may redeem a card iff it issued the card or shares
# the issuer's redemption group. Open network redemption (any merchant
# redeems any card) is closed from Phase 3 on.
module Merchants
  module CanRedeem
    module_function

    # @param redeemer [Merchant] the merchant presenting the token
    # @param issuer   [Merchant] the card's merchant
    def call(redeemer:, issuer:)
      return false if redeemer.nil? || issuer.nil?
      return true if redeemer.id == issuer.id
      return false if issuer.redemption_group_id.nil?

      redeemer.redemption_group_id == issuer.redemption_group_id
    end
  end
end
