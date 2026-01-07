module Auth
  class TokenError < StandardError
    attr_reader :code, :status

    def initialize(code:, message:, status: :unauthorized)
      super(message)
      @code = code
      @status = status
    end
  end
end

