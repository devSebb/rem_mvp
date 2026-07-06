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

  # Type A refund: reverse a redemption capture back onto the card (no money
  # moves at Stripe). Merchants may do this for their own redemptions.
  def refund?
    return false unless user.present?
    return true if user.admin?
    user.merchant? && record.merchant&.user_id == user.id
  end

  # Type B refund: real Stripe refund to the buyer's payment method. Moves
  # platform money out, so this is an admin-only function — merchants must
  # never be able to trigger buyer payouts.
  def stripe_refund?
    user&.admin?
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
