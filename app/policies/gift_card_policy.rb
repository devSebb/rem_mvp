class GiftCardPolicy < ApplicationPolicy
  def show?
    user.present? && (record.sender == user || record.recipient == user || user.admin?)
  end

  def create?
    user.present?
  end

  def checkout?
    user.present?
  end

  def index?
    user.present?
  end

  class Scope < Scope
    def resolve
      if user.admin?
        scope.all
      else
        scope.where(sender: user).or(scope.where(recipient: user))
      end
    end
  end
end
