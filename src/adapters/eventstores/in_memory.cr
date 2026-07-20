module ES
  module EventStoreAdapters
    class InMemory < ES::EventStore
      @events : Hash(UUID, ES::EventStore::Event) = Hash(UUID, ES::EventStore::Event).new
      @tag_versions : Hash(String, Int32) = Hash(String, Int32).new
      @mutex : Mutex = Mutex.new

      # Initialize with an optional queue adapter
      def initialize(@queue : ES::QueueAdapters::InMemory? = nil)
      end

      # Initializes the database with the necessary schema, table and permissions for the eventstore
      def setup
        # Noop
      end

      # Atomically appends a batch of events, guarded by an append condition
      def append(events : Array(ES::Event), condition : ES::AppendCondition = ES::AppendCondition.none)
        @mutex.synchronize do
          staged = @tag_versions.dup

          condition.expected.each do |key, expected|
            actual = staged.fetch(key, 0)
            raise ES::Exception::Conflict.new("Sequence '#{key}' is at version '#{actual}', expected version '#{expected}'") if actual != expected
          end

          events.each do |event|
            event.memberships.each do |key, version|
              next_version = staged.fetch(key, 0) + 1
              raise ES::Exception::Conflict.new("Non-contiguous version for sequence '#{key}': provided version '#{version}', expected version '#{next_version}'") if version != next_version
              staged[key] = version
            end
          end

          # All checks passed, commit the batch
          @tag_versions = staged
          events.each do |event|
            @events[event.header.event_id] = ES::EventStore::Event.new(JSON.parse(event.header.to_json), JSON.parse(event.body.to_json))

            q = @queue
            q.append(event) unless q.nil?
          end
        end
      end

      # Returns a single event for a given id
      def fetch_event(event_id : UUID) : ES::EventStore::Event
        event = @events.fetch(event_id, nil)
        raise ES::Exception::NotFound.new("Event '#{event_id}' not found in eventstore") if event.nil?

        ES::EventStore::Event.new(event.header, event.body)
      end

      # Streams all events in global chronological order (insertion order)
      def each_event(until_event_id : UUID? = nil, batch_size : Int64 = 1000, &block : ES::EventStore::Event ->)
        if uid = until_event_id
          raise ES::Exception::NotFound.new("Event '#{uid}' not found in eventstore") unless @events.has_key?(uid)
        end

        @events.each do |event_id, event|
          block.call(ES::EventStore::Event.new(event.header, event.body))
          break if event_id == until_event_id
        end
      end

      # Returns the event_id of the most recently appended event, or nil if the store is empty
      def last_event_id : UUID?
        @events.last_key?
      end

      # Returns the last version of the given sequence (aggregate_id or tag), 0 if empty
      def last_version(sequence_key : String) : Int32
        @tag_versions.fetch(sequence_key, 0)
      end

      # Returns the stream of events for a given aggregate
      def fetch_events(aggregate_id : UUID) : Array(ES::EventStore::Event)
        event_array = Array(ES::EventStore::Event).new

        @events.each do |event_id, event|
          event_header = JSON.parse(event.header.to_json)
          event_body = JSON.parse(event.body.to_json)

          es_ev = ES::EventStore::Event.new(event_header, event_body)

          uuid = UUID.new(es_ev.header["aggregate_id"].to_s)

          event_array << es_ev if uuid == aggregate_id
        end

        event_array
      end

      # Returns the stream of events for a given sequence key (aggregate_id or tag), ordered by that sequence's version
      def fetch_events(tag : String) : Array(ES::EventStore::Event)
        members = Array({Int32, ES::EventStore::Event}).new

        @events.each_value do |event|
          version = sequence_version(event.header, tag)
          members << {version, ES::EventStore::Event.new(event.header, event.body)} unless version.nil?
        end

        members.sort_by! { |version, _| version }
        members.map { |_, event| event }
      end

      # Returns the version of the event within the given sequence, or nil if it is not a member
      private def sequence_version(header : JSON::Any, tag : String) : Int32?
        return header["aggregate_version"].as_i if header["aggregate_id"].to_s == tag

        if tags = header["tags"]?
          tags[tag]?.try(&.as_i)
        end
      end
    end
  end
end
