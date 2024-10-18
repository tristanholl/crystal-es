module ES
  module Exception
    class InvalidState < Error
      def initialize(
        message = "Invalid state",
        status_code : HTTP::Status = HTTP::Status::INTERNAL_SERVER_ERROR
      )
        super(message, print_backtrace: true, status_code: status_code, type: self.class.to_s)
      end
    end
  end
end
