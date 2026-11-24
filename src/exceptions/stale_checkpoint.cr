module ES
  module Exception
    # A subscription's position moved while it was processing: it was reset or
    # rebuilt, or another instance took the subscription over. The work done
    # since the stale position is rolled back, and the subscription reads its
    # position again. Not a failure of the handler.
    class StaleCheckpoint < Conflict
      def initialize(message = "Subscription position moved meanwhile")
        super(message, status_code: HTTP::Status::CONFLICT)
      end
    end
  end
end
