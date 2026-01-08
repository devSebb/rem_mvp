class MerchantPolicy < ApplicationPolicy
  def update_logo?
    user.present? && (user.admin? || owns_merchant?)
  end

  class Scope < Scope
    def resolve
      return scope.all if user&.admin?
      return scope.where(user_id: user.id) if user&.merchant?

      scope.none
    end
  end

  private

  def owns_merchant?
    user.merchant? && record.user_id == user.id
  end
end

