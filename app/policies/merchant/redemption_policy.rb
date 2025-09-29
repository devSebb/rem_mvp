class Merchant::RedemptionPolicy < ApplicationPolicy
  def new?
    user.present? && user.merchant?
  end

  def create?
    user.present? && user.merchant?
  end

  def confirm?
    user.present? && user.merchant?
  end

  class Scope < Scope
    def resolve
      if user.merchant?
        scope.joins(:merchant).where(merchants: { user: user })
      else
        scope.none
      end
    end
  end
end
