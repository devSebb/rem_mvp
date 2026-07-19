# A declined purchase attempt. No money moved and no gift card exists —
# these rows exist purely for visibility (lost sales used to be email-only).
# One row per PaymentIntent; repeat declines bump attempts. resolved_at is
# set when the same PI later succeeds (buyer retried and got through).
class PaymentFailure < ApplicationRecord
  belongs_to :sender, class_name: "User", optional: true
  belongs_to :merchant, optional: true

  validates :payment_intent_id, presence: true, uniqueness: true

  scope :unresolved, -> { where(resolved_at: nil) }
  scope :recent_first, -> { order(last_failed_at: :desc) }

  # Upsert from a Stripe PaymentIntent. Concurrency-safe via the unique
  # index: a racing insert falls through to the update path.
  def self.record_attempt!(payment_intent)
    error = payment_intent.try(:last_payment_error)
    metadata = payment_intent.metadata || {}
    now = Time.current

    attrs = {
      amount: payment_intent.amount.to_i,
      currency: payment_intent.currency&.upcase || "USD",
      sender_id: metadata["sender_id"].presence&.to_i,
      merchant_id: metadata["merchant_id"].presence&.to_i,
      error_code: error.try(:code).to_s.presence,
      decline_code: error.try(:decline_code).to_s.presence,
      error_message: error.try(:message).to_s.presence,
      last_failed_at: now
    }

    begin
      failure = find_by(payment_intent_id: payment_intent.id)
      if failure
        failure.update!(attrs.merge(attempts: failure.attempts + 1))
        failure
      else
        create!(attrs.merge(payment_intent_id: payment_intent.id, first_failed_at: now))
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end
  end
end
