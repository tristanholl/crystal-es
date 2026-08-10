module ES
  module Exception
    # Raised when an event body cannot be read because its encryption key was
    # deliberately destroyed. The data is gone by design — this is the expected
    # outcome of an erasure request, not a fault to be retried.
    class KeyDestroyed < Error
      def initialize(
        message = "Encryption key destroyed",
        status_code : HTTP::Status = HTTP::Status::GONE,
      )
        super(message, print_backtrace: true, status_code: status_code, type: self.class.to_s)
      end
    end
  end
end
