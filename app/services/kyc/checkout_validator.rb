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
      # Rails 7.2: errors.slice was removed, use select instead
      error_hash = REQUIRED_FIELDS.each_with_object({}) do |field, hash|
        if user.errors[field].any?
          hash[field] = user.errors[field]
        end
      end
      {
        ok: missing.empty?,
        missing: missing.map(&:to_s),
        errors: error_hash
      }
    end

    private

    attr_reader :user
  end
end

