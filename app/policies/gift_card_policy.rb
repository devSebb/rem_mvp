class GiftCardPolicy < ApplicationPolicy
  # Who may see a card (§5.10): its recipient, anyone who has paid a load
  # onto it, and admins. The deprecated card `sender_id` is never read.
  def show?
    user.present? && (record.recipient == user || user.admin? || record.sent_by?(user))
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

  # Only recipients (and admins) can see the raw gift card code / mint a
  # redemption token.
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

  # Card-level sharing compat shim (§5.9): allowed for anyone who paid a
  # load onto the card; the controller resolves which load. Per-load
  # authorization lives in GiftCardLoadPolicy.
  def share?
    user.present? && (user.admin? || record.sent_by?(user))
  end

  # transfer? removed (D9): balance never moves between users.

  # Admin-only: review held loads + release a hold early. Held-load
  # management is a fraud-team function, not for merchants.
  def index_holds?
    user&.admin?
  end

  def release_hold?
    user&.admin?
  end

  # Admin-only card actions (§5.8, §9): freeze/unfreeze for confirmed fraud,
  # cancel only at zero balance (enforced by the controller/model).
  def freeze?
    user&.admin?
  end

  def unfreeze?
    user&.admin?
  end

  def cancel_card?
    user&.admin?
  end

  class Scope < Scope
    # Wallet semantics for everyone, admins included: your own cards only
    # (received, or any card you have loaded). Admins browse the platform
    # through Admin::GiftCardsController; returning scope.all here leaked
    # every card to any admin account acting as a consumer.
    def resolve
      scope.where(recipient_id: user.id)
           .or(scope.where(id: GiftCardLoad.in_scope.where(sender_id: user.id).select(:gift_card_id)))
    end
  end
end
