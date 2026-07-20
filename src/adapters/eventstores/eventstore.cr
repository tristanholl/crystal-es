module ES
  abstract class EventStore
    # Atomically appends a batch of events, guarded by an append condition (the DCB primitive).
    # Raises ES::Exception::Conflict if any sequence in the condition advanced past its
    # expected version, or if the staged versions are not contiguous with the stored ones.
    abstract def append(events : Array(ES::Event), condition : ES::AppendCondition = ES::AppendCondition.none)

    abstract def fetch_events(aggregate_id : UUID) : Array(ES::EventStore::Event)
    abstract def fetch_events(tag : String) : Array(ES::EventStore::Event)
    abstract def fetch_event(event_id : UUID) : ES::EventStore::Event
    abstract def setup
    abstract def each_event(until_event_id : UUID? = nil, batch_size : Int64 = 1000, &block : ES::EventStore::Event ->)
    abstract def last_event_id : UUID?

    # Returns the last version of the given sequence (aggregate_id or tag), 0 if empty
    abstract def last_version(sequence_key : String) : Int32

    # Appends a single event, optionally guarded by an append condition
    def append(event : ES::Event, condition : ES::AppendCondition = ES::AppendCondition.none)
      append([event], condition)
    end

    struct Event
      getter header : JSON::Any
      getter body : JSON::Any

      # Initialize Event with header and body
      def initialize(
        @header : JSON::Any,
        @body : JSON::Any,
      )
      end
    end
  end
end
