# Per-load authorization (RELOADABLE_CARD_PLAN.md §5.10). A load is visible
# to the card's recipient and to the buyer who paid it; sender-only actions
# (share link, resend) belong to that buyer; money actions are admin-only.
class GiftCardLoadPolicy < ApplicationPolicy
  def show?
    return false unless user.present?

    user.admin? || record.sender_id == user.id || record.gift_card&.recipient_id == user.id
  end

  def share?
    user.present? && (user.admin? || record.sender_id == user.id)
  end

  def resend?
    share?
  end

  def stripe_refund?
    user&.admin?
  end

  def release_hold?
    user&.admin?
  end

  class Scope < Scope
    def resolve
      scope.where(sender_id: user.id)
           .or(scope.where(gift_card_id: GiftCard.where(recipient_id: user.id).select(:id)))
    end
  end
end
