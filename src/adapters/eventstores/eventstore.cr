module ES
  abstract class EventStore
    abstract def append(event : ES::Event)
    abstract def fetch_events(aggregate_id : UUID) : Array(ES::EventStore::Event)
    abstract def fetch_event(event_id : UUID) : ES::EventStore::Event
    abstract def setup

    struct Event
      getter header : JSON::Any
      getter body : JSON::Any

      # Initialize Event with header and body
      def initialize(
        @header : JSON::Any,
        @body : JSON::Any
      )
      end
    end
  end
end
