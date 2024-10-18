module ES
  module Exception
    abstract class Error < ::Exception
      struct Information
        include JSON::Serializable

        property id : UUID = UUID.v7
        property type : String
        property message : String?
        property timestamp : Time

        def initialize(
          @message : String?,
          @timestamp : Time,
          @type : String
        )
        end
      end

      getter print_backtrace : Bool
      getter info : Information
      getter status_code : HTTP::Status

      def initialize(
        message = "Generic Error",
        @print_backtrace = false,
        @status_code : HTTP::Status = HTTP::Status::INTERNAL_SERVER_ERROR,
        timestamp = Time.utc,
        type = self.class.to_s
      )
        super(message)
        @info = Information.new(message, timestamp, type)
      end

      def print_backtrace?
        @print_backtrace
      end
    end
  end
end
