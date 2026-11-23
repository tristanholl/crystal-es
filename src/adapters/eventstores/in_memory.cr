module ES
  module EventStoreAdapters
    class InMemory < ES::EventStore
      @events : Hash(UUID, ES::EventStore::Event) = Hash(UUID, ES::EventStore::Event).new

      # Global position of each event, in append order, starting at 1
      @positions : Hash(UUID, Int64) = Hash(UUID, Int64).new
      @position : Int64 = 0_i64

      # Current version of every stored tag
      @tag_versions : Hash(String, Int64) = Hash(String, Int64).new

      # Makes an append's check, version assignment and insert one step, and
      # keeps reads from iterating while an append changes the store
      @mutex = Mutex.new

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

      # Appends an event to the event stream and returns its position
      def append(event : ES::Event)
        append_batch([event.as(ES::Event)], nil)
      end

      # Appends a batch atomically, failing with `ES::Exception::Conflict` if a
      # tag the condition names is no longer at the expected version
      protected def append_batch(events : Array(ES::Event), condition : ES::AppendCondition?) : Int64
        encoded = encode_events(events)
        expected = condition.try { |cond| expected_versions(cond) } || {} of String => Int64

        @mutex.synchronize do
          # The Postgres store refuses a repeated event id through its unique
          # index; overwriting the stored event here would hide the same mistake.
          event_ids = encoded.map(&.event.header.event_id)
          if event_ids.uniq.size != event_ids.size || event_ids.any? { |event_id| @events.has_key?(event_id) }
            raise ES::Exception::Conflict.new("An event id in the batch is already stored or repeated", status_code: HTTP::Status::CONFLICT)
          end

          if mismatch = version_mismatch(expected, @tag_versions)
            raise append_conflict(mismatch)
          end

          # Assigned on a copy, so a failure below leaves the versions untouched
          current = @tag_versions.dup
          versions = assign_versions(encoded, current)
          stored_events = encoded.map_with_index do |event, index|
            ES::EventStore::Event.new(JSON.parse(stored_header(event, versions[index])), JSON.parse(event.body))
          end
          @tag_versions = current

          encoded.each_with_index do |event, index|
            event_id = event.event.header.event_id
            stored = stored_events[index]
            @position += 1
            @events[event_id] = stored
            @positions[event_id] = @position

            q = @queue
            q.append(stored.header) unless q.nil?
          end

          @position
        end
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

        snapshot.each do |event_id, event, _|
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

        snapshot.each do |_, event, position|
          break if limit && result.size >= limit

          next if after && position <= after
          next unless event_matches?(event.header, items)

          result << decode_or_erase(event.header, event.body, position)
        end

        result
      end

      # Returns the events matching a query and the current versions of its tags,
      # both as of one moment
      def read_for_decision(query : ES::Query) : ES::Decision
        items = encode_query(query)
        tags = decision_tags(items)

        events, versions = @mutex.synchronize do
          {
            @events.compact_map { |event_id, event| {event_id, event} if event_matches?(event.header, items) }
              .map { |event_id, event| {event, @positions[event_id]} },
            tags.to_h { |tag| {tag, @tag_versions.fetch(tag, 0_i64)} },
          }
        end

        ES::Decision.new(events.map { |event, position| decode_or_erase(event.header, event.body, position) }, versions)
      end

      # The stored events with their positions as of now, so iterating them never
      # races an append and a caller's block may append without deadlocking
      private def snapshot : Array({UUID, ES::EventStore::Event, Int64})
        @mutex.synchronize { @events.map { |event_id, event| {event_id, event, @positions[event_id]} } }
      end

      # Returns the stream of events for a given aggregate
      def fetch_events(aggregate_id : UUID) : Array(ES::EventStore::Event)
        event_array = Array(ES::EventStore::Event).new

        snapshot.each do |_, event, _|
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
