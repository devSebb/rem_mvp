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

  # Only recipients (and admins) can see the raw gift card code
  def view_code?
    user.present? && (record.recipient == user || user.admin?)
  end

  # Only admins can issue refunds
  def refund?
    user.present? && user.admin?
  end

  # Only recipients can transfer their gift cards
  def transfer?
    user.present? && record.recipient == user && record.active?
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
