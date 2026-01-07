module Jwt
  class Encode
    ALGORITHM = "HS256".freeze

    def self.call(payload:, exp: default_exp)
      payload_with_exp = payload.merge(exp: exp.to_i)
      JWT.encode(payload_with_exp, secret, ALGORITHM)
    end

    def self.default_exp
      15.minutes.from_now
    end

    def self.secret
      ENV["JWT_SECRET"].presence || Rails.application.secret_key_base
    end
  end
end

