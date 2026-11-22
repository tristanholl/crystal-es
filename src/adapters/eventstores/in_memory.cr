module ES
  module EventStoreAdapters
    class InMemory < ES::EventStore
      @events : Hash(UUID, ES::EventStore::Event) = Hash(UUID, ES::EventStore::Event).new

      # Global position of each event, in append order, starting at 1
      @positions : Hash(UUID, Int64) = Hash(UUID, Int64).new
      @position : Int64 = 0_i64

      # Initialize with an optional queue adapter, payload encryption and tag hashing
      def initialize(
        @queue : ES::QueueAdapters::InMemory? = nil,
        @encryption : ES::EncryptionKeyManager? = ES::Config.encryption?,
        @tag_hasher : ES::TagHasher? = ES::Config.tag_hasher?,
      )
      end

      # Initializes the database with the necessary schema, table and permissions for the eventstore
      def setup
        # Noop
      end

      # Appends an event to the event stream
      def append(event : ES::Event)
        stored = ES::EventStore::Event.new(JSON.parse(encode_header(event)), JSON.parse(encode_body(event)))
        @position += 1
        @events[event.header.event_id] = stored
        @positions[event.header.event_id] = @position

        q = @queue
        q.append(stored.header) unless q.nil?
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

      # Returns the events matching a query, in append order
      def read(query : ES::Query, after : Int64? = nil, limit : Int32? = nil) : Array(ES::EventStore::Event)
        validate_read_options(after, limit)
        items = encode_query(query)
        result = Array(ES::EventStore::Event).new

        @events.each do |event_id, event|
          break if limit && result.size >= limit

          position = @positions[event_id]
          next if after && position <= after
          next unless matches?(event.header, items)

          result << decode_or_erase(event.header, event.body, position)
        end

        result
      end

      # Whether a stored header matches any item of an encoded query
      private def matches?(header : JSON::Any, items : Array(EncodedQueryItem)) : Bool
        handle = header["event_handle"].as_s
        tags = header["tags"]?.try(&.as_a.map(&.as_s)) || [] of String

        items.any? do |item|
          (item.types.empty? || item.types.includes?(handle)) && item.tags.all? { |tag| tags.includes?(tag) }
        end
      end

      # Returns the stream of events for a given aggregate
      def fetch_events(aggregate_id : UUID) : Array(ES::EventStore::Event)
        event_array = Array(ES::EventStore::Event).new

        @events.each_value do |event|
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
