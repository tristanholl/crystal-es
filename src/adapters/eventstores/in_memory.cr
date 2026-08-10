module ES
  module EventStoreAdapters
    class InMemory < ES::EventStore
      @events : Hash(UUID, ES::EventStore::Event) = Hash(UUID, ES::EventStore::Event).new

      # Initialize with an optional queue adapter and payload encryption
      def initialize(
        @queue : ES::QueueAdapters::InMemory? = nil,
        @encryption : ES::EncryptionKeyManager? = ES::Config.encryption?,
      )
      end

      # Initializes the database with the necessary schema, table and permissions for the eventstore
      def setup
        # Noop
      end

      # Appends an event to the event stream
      def append(event : ES::Event)
        @events[event.header.event_id] = ES::EventStore::Event.new(JSON.parse(event.header.to_json), JSON.parse(encode_body(event)))

        q = @queue
        q.append(event) unless q.nil?
      end

      # Returns a single event for a given id
      def fetch_event(event_id : UUID) : ES::EventStore::Event
        event = @events.fetch(event_id, nil)
        raise ES::Exception::NotFound.new("Event '#{event_id}' not found in eventstore") if event.nil?

        decode(event.header, event.body)
      end

      # Streams all events in global chronological order (insertion order)
      def each_event(until_event_id : UUID? = nil, batch_size : Int64 = 1000, &block : ES::EventStore::Event ->)
        if uid = until_event_id
          raise ES::Exception::NotFound.new("Event '#{uid}' not found in eventstore") unless @events.has_key?(uid)
        end

        @events.each do |event_id, event|
          if es_event = decode_or_skip(event.header, event.body)
            block.call(es_event)
          end
          break if event_id == until_event_id
        end
      end

      # Returns the event_id of the most recently appended event, or nil if the store is empty
      def last_event_id : UUID?
        @events.last_key?
      end

      # Returns the encryption keys used across an aggregate's stream
      def encryption_key_ids(aggregate_id : UUID) : Array(UUID)
        key_ids = Array(UUID).new

        @events.each_value do |event|
          next unless UUID.new(event.header["aggregate_id"].to_s) == aggregate_id

          id = event.header["encryption_key_id"]?.try(&.as_s?)
          next if id.nil?

          key_id = UUID.new(id)
          key_ids << key_id unless key_ids.includes?(key_id)
        end

        key_ids
      end

      # Returns the stream of events for a given aggregate
      def fetch_events(aggregate_id : UUID) : Array(ES::EventStore::Event)
        event_array = Array(ES::EventStore::Event).new

        @events.each do |event_id, event|
          event_header = JSON.parse(event.header.to_json)
          event_body = JSON.parse(event.body.to_json)

          uuid = UUID.new(event_header["aggregate_id"].to_s)

          event_array << decode(event_header, event_body) if uuid == aggregate_id
        end

        event_array
      end
    end
  end
end
