class Merchant < ApplicationRecord
  include MerchantCategories

  # Business deal with Farmaenlace: cards for partner-routed merchants are
  # paid at these stores, which then reroute funds to the merchant off-platform.
  DEFAULT_REDEMPTION_PARTNER_LABEL = "Medicity o Farmacias Económicas".freeze

  attr_reader :generated_secret_key

  belongs_to :user
  has_many :gift_cards, dependent: :nullify
  has_many :transactions, through: :gift_cards
  has_many :settlements, dependent: :destroy
  has_one_attached :logo

  enum status: { active: 0, suspended: 1 }

  # ── Unsettled money ─────────────────────────────────────────────────
  # Transactions dated outside every existing settlement period. Shared by
  # the admin payout flow and the merchant dashboard so "pendiente" always
  # means the same thing on both sides. Note: transactions here are the
  # ones REDEEMED BY this merchant (merchant_id on the row), not the
  # through-gift_cards association above (issuer semantics).

  def unsettled_redemptions
    excluding_settled_periods(Transaction.successful.redemptions.where(merchant_id: id))
  end

  def unsettled_reversals
    excluding_settled_periods(Transaction.successful.reversals.where(merchant_id: id))
  end

  # What we actually still owe for redemptions (before commission): net of
  # reversals. Can be negative when reversals outpace new redemptions —
  # payout creation blocks on that instead of hiding it.
  def unsettled_net_redeemed_cents
    unsettled_redemptions.sum(:amount) - unsettled_reversals.sum(:amount)
  end

  private def excluding_settled_periods(scope)
    settlements.each { |s| scope = scope.where.not(created_at: s.period_range) }
    scope
  end

  validates :store_name, presence: true
  validates :name, presence: true
  validates :public_key, presence: true, uniqueness: true
  validates :secret_key_digest, presence: true, uniqueness: true
  validates :contact_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validate :validate_logo

  before_validation :sync_display_name
  before_validation :ensure_api_keys

  def self.digest_secret(raw)
    return if raw.blank?

    Digest::SHA256.hexdigest(raw)
  end

  def self.generate_keys!(merchant)
    raw_secret = "sec_#{SecureRandom.hex(32)}"
    public_key = "pub_#{SecureRandom.hex(16)}"

    merchant.update!(
      public_key: public_key,
      secret_key_digest: digest_secret(raw_secret)
    )

    merchant.instance_variable_set(:@generated_secret_key, raw_secret)
    { public_key: public_key, secret_key: raw_secret }
  end

  def authenticate_secret(raw)
    return false if raw.blank? || secret_key_digest.blank?

    candidate = self.class.digest_secret(raw)
    return false if candidate.blank?

    ActiveSupport::SecurityUtils.secure_compare(secret_key_digest, candidate)
  end

  def redemption_partner_display
    redemption_partner_label.presence || DEFAULT_REDEMPTION_PARTNER_LABEL
  end

  # Shown verbatim by the mobile app on the merchant profile ("Canje" section).
  # Falls back to the partner disclaimer so flagged merchants surface it even
  # when no custom coverage text has been written in the admin.
  def effective_coverage_text
    return coverage_text.strip if coverage_text.present?
    return unless partner_redemption?

    "Para canjear esta tarjeta, paga en #{redemption_partner_display}."
  end

  def admin_delete_blockers
    blockers = []
    blockers << "tarjetas de regalo" if gift_cards.exists?
    blockers << "transacciones" if Transaction.where(merchant_id: id).exists?
    blockers << "liquidaciones" if settlements.exists?

    if user
      blockers << "historial de tarjetas del usuario" if user.sent_gift_cards.exists? || user.received_gift_cards.exists?
      blockers << "transacciones del usuario" if Transaction.where(user_id: user.id).exists?
    end

    blockers
  end

  def admin_deletable?
    admin_delete_blockers.empty?
  end

  private

  # `name` is a legacy mirror of `store_name`, added alongside the merchant API
  # credentials and still part of the v1 merchant response shape. Nothing edits
  # it directly — the admin form only exposes `store_name` — so it is kept in
  # lockstep on every save. It previously only filled in when blank, which left
  # `name` frozen at the value a merchant was created with: renaming a store
  # updated `store_name` everywhere but the receipt email and the API kept
  # printing the original name.
  def sync_display_name
    self.name = store_name if store_name.present?
  end

  def ensure_api_keys
    self.public_key ||= "pub_#{SecureRandom.hex(16)}"
    return if secret_key_digest.present?

    raw_secret = "sec_#{SecureRandom.hex(32)}"
    @generated_secret_key = raw_secret
    self.secret_key_digest = self.class.digest_secret(raw_secret)
  end

  def validate_logo
    return unless logo.attached?

    if logo.blob.byte_size > 5.megabytes
      errors.add(:logo, "is too large (max 5MB)")
    end

    return if logo.content_type&.start_with?("image/")

    errors.add(:logo, "must be an image")
  end
end
