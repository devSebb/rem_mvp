class MerchantPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def update_logo?
    user.present? && (user.admin? || owns_merchant?)
  end

  class Scope < Scope
    def resolve
      return scope.all if user&.admin?
      return scope.where(user_id: user.id) if user&.merchant?

      # Regular authenticated users can see active merchants for browsing
      return scope.where(status: :active) if user.present?

      scope.none
    end
  end

  private

  def owns_merchant?
    user.merchant? && record.user_id == user.id
  end
end

