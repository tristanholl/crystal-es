module ES
  module Exception
    class Conflict < Error
      def initialize(
        message = "Conflict",
        status_code : HTTP::Status = HTTP::Status::BAD_REQUEST
      )
        super(message, print_backtrace: true, status_code: status_code, type: self.class.to_s)
      end
    end
  end
end
