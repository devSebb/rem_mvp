module Jwt
  class Decode
    ALGORITHM = Jwt::Encode::ALGORITHM

    def self.call(token:)
      decoded, = JWT.decode(token, Jwt::Encode.secret, true, { algorithm: ALGORITHM })
      decoded
    end
  end
end

