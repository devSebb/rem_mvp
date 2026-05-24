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

  def refund?
    return false unless user.present?
    return true if user.admin?
    user.merchant? && record.merchant&.user_id == user.id
  end

  # Only recipients can transfer their gift cards
  def transfer?
    user.present? && record.recipient == user && record.active?
  end

  # Admin-only: review held cards + release a hold early. Held-card
  # management is a fraud-team function, not for merchants.
  def index_holds?
    user&.admin?
  end

  def release_hold?
    user&.admin?
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
