module Kyc
  class CheckoutValidator
    REQUIRED_FIELDS = %i[address country_of_residence date_of_birth].freeze

    def self.call(user:)
      new(user).call
    end

    def initialize(user)
      @user = user
    end

    def call
      missing = REQUIRED_FIELDS.select { |field| user.public_send(field).blank? }

      user.valid?(:checkout_kyc)
      {
        ok: missing.empty?,
        missing: missing.map(&:to_s),
        errors: user.errors.slice(*REQUIRED_FIELDS).to_hash(full_messages: true)
      }
    end

    private

    attr_reader :user
  end
end

