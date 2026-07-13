class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable

  # Enums
  enum role: { user: 0, merchant: 1, admin: 2 }
  enum preferred_channel: { whatsapp: 0, sms: 1 }, _prefix: :prefers

  attr_accessor :skip_national_id_validation
  attr_accessor :terms_accepted
  # Set to true by the mobile API signup path so a fresh account is created
  # UNVERIFIED (email_verified_at stays nil) and must confirm an emailed code
  # before any tokens are issued. All other creation paths (web signup,
  # console, tests) leave this nil and are auto-verified on create.
  attr_accessor :require_email_verification
  # Set to true when the Stripe webhook creates a recipient shell. Suppresses
  # the default-claim callback so claimed_at stays nil until the real owner
  # signs up. All other code paths (web signup, API signup, console) leave
  # this nil and get claimed_at = Time.current automatically.
  attr_accessor :pending_recipient

  # Associations
  has_one :merchant, dependent: :destroy
  has_many :sent_gift_cards, class_name: 'GiftCard', foreign_key: 'sender_id', dependent: :nullify
  has_many :received_gift_cards, class_name: 'GiftCard', foreign_key: 'recipient_id', dependent: :nullify
  has_many :push_tokens, dependent: :destroy
  has_one_attached :avatar

  # Constants
  # Placeholder email for "pending" users created when someone is sent a gift
  # card but hasn't signed up yet. Format: claim+<phone-hash>@papayal.app.
  # Detected by this prefix so notifier can skip real email delivery.
  CLAIM_EMAIL_PREFIX = "claim+"
  CLAIM_EMAIL_DOMAIN = "papayal.app"

  # Placeholder email for deleted accounts. Format: deleted+<id>@papayal.app.
  # Frees the original email for future signups while keeping the user row
  # intact so gift_cards foreign keys remain valid.
  DELETED_EMAIL_PREFIX = "deleted+"

  # Scopes
  scope :active, -> { where(deleted_at: nil) }

  # Validations
  # email is always required (Devise :validatable enforces presence + format)
  # first_name / last_name / phone only required for fully-claimed accounts;
  # pending recipients (received a gift card, not yet signed up) can have nulls.
  validates :first_name, :last_name, :phone, presence: true, if: :claimed?
  validates :phone, uniqueness: true, allow_nil: true
  validates :role, presence: true
  validates :terms_accepted, acceptance: { message: "debes aceptar los términos y condiciones para registrarte" }, on: :create, if: :claimed?
  validates :national_id,
            format: {
              with: /\A[a-zA-Z0-9]{7,}\z/,
              message: "must be at least 7 alphanumeric characters"
            },
            allow_blank: true
  validate :validate_avatar
  with_options on: :checkout_kyc do
    validates :address, :country_of_residence, :date_of_birth, presence: true
  end

  before_validation :default_claimed_at_on_create, on: :create
  before_validation :default_email_verified_on_create, on: :create
  before_validation :normalize_contact_fields
  before_validation :sync_name_fields
  before_validation :normalize_national_id

  # Send a welcome email for fresh signups only. Pending recipients
  # (created via the Stripe webhook for someone who received a gift card
  # but hasn't signed up) are skipped — their `pending_recipient` flag is
  # set, and they have a placeholder email anyway. When a pending account
  # is later claimed via signup, the claim path is an UPDATE (not CREATE),
  # so this callback won't fire — the controllers send the welcome email
  # explicitly in that branch.
  after_create_commit :send_welcome_email_if_real_signup

  # Methods
  def merchant?
    role == 'merchant'
  end

  def admin?
    role == 'admin'
  end

  def full_name
    [first_name, last_name].compact_blank.join(" ")
  end

  # A user is "claimed" once they've completed signup themselves.
  # Recipients of gift cards are created as pending (claimed_at: nil) until
  # they sign up with the matching email or phone, at which point they
  # claim the existing account record.
  def claimed?
    claimed_at.present?
  end

  def pending?
    !claimed?
  end

  def deleted?
    deleted_at.present?
  end

  # A user has verified their email once they've confirmed the emailed code
  # (or was auto-verified on a non-mobile-signup path / backfilled). The
  # mobile API refuses to issue tokens until this is true.
  def email_verified?
    email_verified_at.present?
  end

  # Deterministic placeholder email for a deleted account.
  def self.deleted_email_for(id)
    "#{DELETED_EMAIL_PREFIX}#{id}@#{CLAIM_EMAIL_DOMAIN}"
  end

  # The email is a placeholder we generated for a phone-only recipient,
  # not a real address. Used by notifier to skip real email delivery.
  def placeholder_email?
    email.to_s.start_with?(CLAIM_EMAIL_PREFIX) && email.to_s.end_with?("@#{CLAIM_EMAIL_DOMAIN}")
  end

  # Generate a deterministic placeholder email for a phone-only recipient.
  # Hashed so the same phone always maps to the same placeholder, ensuring
  # a single pending user record per phone even across multiple gift cards.
  def self.placeholder_email_for_phone(phone)
    return nil if phone.blank?
    digest = Digest::SHA256.hexdigest(phone.to_s.strip)[0, 16]
    "#{CLAIM_EMAIL_PREFIX}#{digest}@#{CLAIM_EMAIL_DOMAIN}"
  end

  private

  def default_claimed_at_on_create
    return if pending_recipient
    self.claimed_at ||= Time.current
  end

  # Auto-verify every creation path EXCEPT the mobile API fresh signup
  # (which sets require_email_verification and drives the emailed-code flow)
  # and pending-recipient shells (verified when their owner claims them).
  def default_email_verified_on_create
    return if require_email_verification
    return if pending_recipient
    self.email_verified_at ||= Time.current
  end

  def send_welcome_email_if_real_signup
    return if pending_recipient
    return if placeholder_email?
    return unless claimed?
    # Unverified fresh signups get their welcome only after they confirm the
    # emailed code (sent explicitly from the verification endpoint) — we
    # don't welcome an address we haven't confirmed is real and reachable.
    return unless email_verified?

    WelcomeMailer.welcome(id).deliver_later
  end

  def normalize_contact_fields
    self.first_name = first_name.to_s.strip.presence if has_attribute?(:first_name)
    self.last_name = last_name.to_s.strip.presence if has_attribute?(:last_name)
    self.name = name.to_s.strip.presence if has_attribute?(:name)
    self.address = address.to_s.strip.presence if has_attribute?(:address)
    self.country_of_residence = country_of_residence.to_s.strip.presence if has_attribute?(:country_of_residence)
    self.phone = phone.to_s.strip.presence if has_attribute?(:phone)
    self.email = email.to_s.strip.downcase if has_attribute?(:email) && email.present?
  end

  def sync_name_fields
    if first_name.blank? && last_name.blank? && name.present?
      self.first_name, self.last_name = split_name(name)
    end

    return unless first_name.present? || last_name.present?

    combined_name = [first_name, last_name].compact_blank.join(" ")
    self.name = combined_name if has_attribute?(:name)
  end

  def normalize_national_id
    return if national_id.blank?

    self.national_id = national_id.to_s.strip.gsub(/[\s-]+/, '').upcase
  end

  def split_name(full_name)
    parts = full_name.to_s.strip.split(/\s+/, 2)
    [parts.first, parts.second.to_s]
  end

  def validate_avatar
    return unless avatar.attached?

    if avatar.blob.byte_size > 5.megabytes
      errors.add(:avatar, "is too large (max 5MB)")
    end

    return if avatar.content_type&.start_with?("image/")

    errors.add(:avatar, "must be an image")
  end
end
