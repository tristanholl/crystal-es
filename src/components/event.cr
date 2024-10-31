module ES
  abstract class Event
    @@aggregate = "AbstractAggregate"
    @@handle = "Abstract"

    # Default header struct of the event
    struct Header
      include JSON::Serializable

      getter actor_id : UUID? = nil
      getter aggregate_id : UUID = UUID.v7
      getter aggregate_type : String = "undefined"
      getter aggregate_version : Int32 = 1
      getter command_handler : String = "undefined"
      getter command_handler_version : String = ES::Config.version
      getter created_at : Time = Time.utc
      getter event_handle : String = "undefined"
      getter event_id : UUID = UUID.v7
      getter event_version : String = "1.0.0"

      # Default constructor
      def initialize; end

      def initialize(
        @actor_id : UUID?,
        @aggregate_id : UUID,
        @aggregate_version : Int32,
        @event_handle : String,
        @event_version = "1.0.0",
        @created_at = Time.utc,
        @aggregate_type = "undefined",
        @command_handler = "undefined",
        @command_handler_version = ES::Config.version
      )
      end
    end

    # Default body struct of the event
    abstract struct Body
      include JSON::Serializable

      getter comment = ""
    end

    getter header : Header
    getter body : Body

    # Returns aggregate the event belongs to
    def self.aggregate
      @@aggregate
    end

    # Returns the event handle
    def self.handle
      @@handle
    end

    def initialize
      @header = ES::Event::Header.new
      @body = ES::Event::Body.new
    end
  end
end
