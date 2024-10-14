module ES
  module EventStoreAdapters
    class InMemory < ES::EventStore
      @events : Hash(UUID, ES::EventStore::Event) = Hash(UUID, ES::EventStore::Event).new

      # Initialize with an optional queue adapter
      def initialize(@queue : ES::QueueAdapters::InMemory? = nil)
      end

      # Initializes the database with the necessary schema, table and permissions for the eventstore
      def setup
        # Noop
      end

      # Appends an event to the event stream
      def append(event : ES::Event)
        @events[event.header.event_id] = ES::EventStore::Event.new(JSON.parse(event.header.to_json), JSON.parse(event.body.to_json))

        q = @queue
        q.append(event) unless q.nil?
      end

      # Returns a single event for a given id
      def fetch_event(event_id : UUID) : ES::EventStore::Event
        event = @events.fetch(event_id, nil)
        raise ES::Exception::NotFound.new("Event '#{event_id}' not found in eventstore") if event.nil?

        ES::EventStore::Event.new(event.header, event.body)
      end

      # Returns the stream of events for a given aggregate
      def fetch_events(aggregate_id : UUID) : Array(ES::EventStore::Event)
        event_array = Array(ES::EventStore::Event).new

        @events.each do |event_id, event|
          event_header = JSON.parse(event.header.to_json)
          event_body = JSON.parse(event.body.to_json)

          es_ev = ES::EventStore::Event.new(event_header, event_body)

          uuid = UUID.new(es_ev.header["aggregate_id"].to_s)

          event_array << ES::EventStore::Event.new(event_header, event_body) if uuid == aggregate_id
        end

        event_array
      end
    end
  end
end
