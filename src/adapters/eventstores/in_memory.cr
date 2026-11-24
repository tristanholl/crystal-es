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

      # Serializes writers: a `transaction` holds it for its whole block, a
      # plain append for the append. Writers taking turns is what lets a
      # rollback restore tag versions without undoing anyone else's raise.
      # Checked, so an append through this store from inside one of its own
      # transactions — one that bypasses the yielded store — raises instead
      # of waiting on itself forever.
      @write_mutex = Mutex.new(:checked)

      # The transaction in progress, if any: the position before its first
      # append, the tag versions to restore on rollback, and queue messages
      # held back until it commits
      @open_transaction : Transaction? = nil

      # :nodoc:
      class Transaction
        getter start_position : Int64
        getter tag_versions : Hash(String, Int64)
        getter queued = [] of JSON::Any
        getter on_commit = [] of Proc(Nil)

        def initialize(@start_position : Int64, @tag_versions : Hash(String, Int64))
        end
      end

      # Coordinates subscriptions on this store; one per store, so every
      # `ES::Subscriptions` on it sees the same positions and locks, like
      # instances sharing a database
      @subscription_store : ES::SubscriptionStoreAdapters::InMemory? = nil

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
        @write_mutex.synchronize { append_unlocked(events, condition) }
      end

      # :nodoc:
      # The append itself, for a caller already holding the write lock: a plain
      # append, or one made through the store bound to a transaction
      def append_unlocked(events : Array(ES::Event), condition : ES::AppendCondition?) : Int64
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

            if open = @open_transaction
              open.queued << stored.header
            elsif q = @queue
              q.append(stored.header)
            end
          end

          @position
        end
      end

      # Runs the block as one transaction: appends through the yielded store are
      # kept if it returns and removed again if it raises. Reads through any
      # store see them at once, except `read_log`, which only reaches them once
      # the transaction committed, as on Postgres. Other writers wait for the
      # transaction to finish.
      def transaction(& : ES::EventStore -> T) : T forall T
        @write_mutex.synchronize do
          open = @mutex.synchronize { @open_transaction = Transaction.new(@position, @tag_versions.dup) }
          begin
            value = yield Bound.new(self)
          rescue ex
            rollback(open)
            raise ex
          end

          @mutex.synchronize { @open_transaction = nil }
          if q = @queue
            open.queued.each { |header| q.append(header) }
          end
          open.on_commit.each(&.call)
          value
        end
      end

      # :nodoc:
      # Runs `block` once the transaction in progress commits; never if it rolls back
      def after_commit(&block : -> Nil) : Nil
        open = @open_transaction
        raise ES::Exception::InvalidState.new("No transaction is in progress") if open.nil?
        open.on_commit << block
      end

      private def rollback(open : Transaction) : Nil
        @mutex.synchronize do
          appended = @positions.select { |_, position| position > open.start_position }.keys
          appended.each do |event_id|
            @events.delete(event_id)
            @positions.delete(event_id)
          end
          @tag_versions = open.tag_versions
          @open_transaction = nil
        end
      end

      # The last position no open transaction can still remove
      def log_head : LogPosition
        @mutex.synchronize { log_head_unlocked }
      end

      private def log_head_unlocked : LogPosition
        open = @open_transaction
        LogPosition.new(0_i64, open ? open.start_position : @position)
      end

      # Reads the events after `after` up to the head, in append order
      def read_log(after : LogPosition, limit : Int32 = 1000, handles : Array(String)? = nil, partition : {Int32, Int32}? = nil) : LogPage
        validate_log_options(limit, partition)

        head, rows = @mutex.synchronize do
          bound = log_head_unlocked
          {bound, @events.compact_map do |event_id, event|
            position = @positions[event_id]
            {event, position} if position > after.id && position <= bound.id
          end}
        end

        events = [] of ES::EventStore::Event
        rows.sort_by! { |_, position| position }.each do |event, position|
          next if handles && !handles.includes?(event.header["event_handle"].as_s)
          next if partition && partition_of(event.header, partition[1]) != partition[0]

          events << decode_or_erase(event.header, event.body, position, LogPosition.new(0_i64, position))
          break if events.size == limit
        end

        last = events.size == limit ? events.last.log_position : head
        LogPage.new(events, last || head)
      end

      # The partition of an event's aggregate. Stable within one process, which
      # is as long as an in-memory store lives.
      private def partition_of(header : JSON::Any, count : Int32) : Int32
        (header["aggregate_id"].as_s.hash % count.to_u64).to_i32
      end

      # Coordinates subscriptions on this store
      def subscription_store(listen_url : String? = nil) : ES::SubscriptionStore
        @subscription_store ||= ES::SubscriptionStoreAdapters::InMemory.new
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

      # The store yielded by `InMemory#transaction`: appends join the
      # transaction, everything else reads the store as usual
      class Bound < ES::EventStore
        def initialize(@store : InMemory)
        end

        # The store this one is bound to
        getter store : InMemory

        def append(event : ES::Event)
          @store.append_unlocked([event.as(ES::Event)], nil)
        end

        protected def append_batch(events : Array(ES::Event), condition : ES::AppendCondition?) : Int64
          @store.append_unlocked(events, condition)
        end

        def transaction(& : ES::EventStore -> T) : T forall T
          yield self
        end

        def setup
          raise ES::Exception::InvalidState.new("setup can't run inside a transaction")
        end

        def fetch_events(aggregate_id : UUID) : Array(ES::EventStore::Event)
          @store.fetch_events(aggregate_id)
        end

        def fetch_event(event_id : UUID) : ES::EventStore::Event
          @store.fetch_event(event_id)
        end

        def each_event(until_event_id : UUID? = nil, batch_size : Int64 = 1000, &block : ES::EventStore::Event ->)
          @store.each_event(until_event_id, batch_size, &block)
        end

        def last_event_id : UUID?
          @store.last_event_id
        end

        def encryption_key_ids(aggregate_id : UUID) : Array(UUID)
          @store.encryption_key_ids(aggregate_id)
        end

        def read(query : ES::Query, after : Int64? = nil, limit : Int32? = nil) : Array(ES::EventStore::Event)
          @store.read(query, after, limit)
        end

        def read_for_decision(query : ES::Query) : ES::Decision
          @store.read_for_decision(query)
        end

        def log_head : LogPosition
          @store.log_head
        end

        def read_log(after : LogPosition, limit : Int32 = 1000, handles : Array(String)? = nil, partition : {Int32, Int32}? = nil) : LogPage
          @store.read_log(after, limit, handles, partition)
        end

        def subscription_store(listen_url : String? = nil) : ES::SubscriptionStore
          @store.subscription_store(listen_url)
        end
      end
    end
  end
end
