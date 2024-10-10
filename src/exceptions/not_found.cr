module ES
  module Exception
    class NotFound < Error
      def initialize(
        message = "Resource not found", 
        status_code : HTTP::Status = HTTP::Status::BAD_REQUEST
      )
        super(message, print_backtrace: true, status_code: status_code, type: self.class.to_s)
      end
    end
  end
end
