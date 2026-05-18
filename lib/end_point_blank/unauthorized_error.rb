module EndPointBlank
  class UnauthorizedError < StandardError
    attr_reader :status

    def initialize(message = nil, status = 401)
      super(message)
      @status = status
    end
  end
end