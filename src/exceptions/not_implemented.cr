module ES
  module Exception
    class NotImplemented < Error
      def initialize(
        message = "Not implemented",
        status_code : HTTP::Status = HTTP::Status::INTERNAL_SERVER_ERROR
      )
        super(message, print_backtrace: true, status_code: status_code, type: self.class.to_s)
      end
    end
  end
end
