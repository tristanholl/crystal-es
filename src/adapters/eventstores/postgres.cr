module ES
  module EventStoreAdapters
    class Postgres < ES::EventStore
      # Serves the lookups by event_id in `fetch_event` and `each_event(until_event_id:)`,
      # which would otherwise scan the whole table, and enforces that event ids never repeat.
      # The expression must stay identical to the one in those queries (no `::uuid` casts)
      # or the planner will not use the index.
      EVENT_ID_INDEX = %(CREATE UNIQUE INDEX IF NOT EXISTS events_event_id_idx ON "eventstore"."events"((header->>'event_id'));)

      # Serves the tag filter of `read`: `header->'tags' @> $n::jsonb`, which is
      # what "carries all of these tags" is in SQL. `jsonb_path_ops` only supports
      # containment, which is all a query needs, and is smaller and faster for it
      # than the default operator class. Headers without tags have no entry.
      TAGS_INDEX = %(CREATE INDEX IF NOT EXISTS events_tags_idx ON "eventstore"."events" USING gin ((header->'tags') jsonb_path_ops);)

      # Serves the type filter of `read`, including items that name types but no tags
      EVENT_HANDLE_INDEX = %(CREATE INDEX IF NOT EXISTS events_event_handle_idx ON "eventstore"."events"((header->>'event_handle'));)

      # Namespace of the advisory locks taken by `append`, the first argument of
      # the two-key `pg_advisory_xact_lock(int, int)`. Keeps them apart from any
      # advisory locks the application takes with the one-key form or its own
      # namespace.
      LOCK_NAMESPACE = IO::ByteFormat::BigEndian.decode(Int32, Digest::SHA256.digest("crystal-es:append")[0, 4])

      # Initialize with a database connection and, optionally, payload encryption
      # and tag hashing
      def initialize(
        @db : DB::Database,
        @encryption : ES::EncryptionKeyManager? = ES::Config.encryption?,
        @tag_hasher : ES::TagHasher? = ES::Config.tag_hasher?,
      )
      end

      # Initializes the database with the necessary schema, table and permissions for the eventstore
      def setup
        skip = @db.query_one %(SELECT EXISTS (SELECT FROM pg_tables WHERE  schemaname = 'eventstore' AND tablename  = 'events');), as: Bool
        if skip
          # Stores created before an index existed get it on their next setup. The
          # event_id one fails if the store holds duplicate event ids, which should
          # never happen. On a large store these builds block appends while they
          # run; create them beforehand with CREATE INDEX CONCURRENTLY to avoid that.
          @db.exec EVENT_ID_INDEX
          @db.exec TAGS_INDEX
          @db.exec EVENT_HANDLE_INDEX
          warn_about_invalid_indexes
          return true
        end

        migrations = Array(String).new
        migrations << %( CREATE SCHEMA IF NOT EXISTS "eventstore"; )
        migrations << %( GRANT USAGE ON SCHEMA "eventstore" TO pg_monitor; )
        migrations << %( GRANT SELECT ON ALL TABLES IN SCHEMA "eventstore" TO pg_monitor; )
        migrations << %( GRANT SELECT ON ALL SEQUENCES IN SCHEMA "eventstore" TO pg_monitor; )
        migrations << %( ALTER DEFAULT PRIVILEGES IN SCHEMA "eventstore" GRANT SELECT ON TABLES TO pg_monitor; )
        migrations << %( ALTER DEFAULT PRIVILEGES IN SCHEMA "eventstore" GRANT SELECT ON SEQUENCES TO pg_monitor; )
        migrations << %(
          CREATE TABLE "eventstore"."events" (
            "id" BIGSERIAL PRIMARY KEY,
            "header" jsonb NOT NULL,
            "body" jsonb NOT NULL
          );
        )

        migrations << %(CREATE UNIQUE INDEX aggregate_id_version_idx ON "eventstore"."events"((header->>'aggregate_id'), (header->>'aggregate_version'));)
        migrations << EVENT_ID_INDEX
        migrations << TAGS_INDEX
        migrations << EVENT_HANDLE_INDEX

        migrations << %(
          CREATE OR REPLACE VIEW "eventstore"."eventstore_flattened"
          AS
          SELECT
            e.id,
            e.header ->> 'aggregate_id' AS "aggregate_id",
            e.header ->> 'event_handle' AS "event_handle",
            e.header ->> 'aggregate_version' AS "aggregate_version",
            e.header ->> 'aggregate_type' AS "aggregate_type",
            e.header,
            e.body
          FROM
            "eventstore"."events" e
          ORDER BY
            id ASC,
            e.header ->> 'aggregate_id' ASC,
            e.header ->> 'aggregate_version' ASC;
        )

        migrations.each { |statement| @db.exec statement }
      end

      # A CREATE INDEX CONCURRENTLY that failed leaves an invalid index behind.
      # `IF NOT EXISTS` skips it because the name exists, and queries then run
      # without it, so it is reported rather than passed over in silence.
      private def warn_about_invalid_indexes
        names = @db.query_all(
          %(SELECT c.relname FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'eventstore' AND NOT i.indisvalid ORDER BY c.relname),
          as: String
        )

        names.each do |name|
          Log.warn { "Index 'eventstore.#{name}' is invalid, most likely from a failed CREATE INDEX CONCURRENTLY, and is not used by queries. Drop it and run setup again." }
        end
      end

      # Lock keys one append may take one by one. A batch carrying more distinct
      # tags and types takes the store-wide key exclusively instead: advisory
      # locks live in Postgres' shared lock table, sized by
      # `max_locks_per_transaction` (64 by default) times the connections, and a
      # large import holding one per tag could exhaust it for the whole cluster.
      MAX_LOCK_KEYS = 64

      # Appends an event to the event stream and returns its position
      def append(event : ES::Event)
        append_batch([event.as(ES::Event)], nil)
      end

      # Appends a batch atomically, failing with `ES::Exception::Conflict` if the
      # condition's query matches an event appended after its position.
      #
      # Positions come from a sequence, which hands them out in the order inserts
      # start, not the order they commit, so checking and inserting in one
      # statement would race. Instead, in one READ COMMITTED transaction:
      #
      # 1. Advisory locks (see `lock_plan`). A conditional append locks what its
      #    query selects exclusively; every append locks what its events carry
      #    shared. Plain appends never wait for each other, while a check waits
      #    for any in-flight append of an event it could match, and blocks new
      #    ones.
      # 2. The check, as its own statement. Under READ COMMITTED each statement
      #    takes a fresh snapshot, so it sees whatever committed while step 1
      #    waited. Folded into the locking statement — or under REPEATABLE READ,
      #    which is why the level is set explicitly — it would not.
      # 3. The inserts.
      #
      # The check alone is not enough: a matching event can commit after a
      # higher-positioned one the decision read, and below the position it checks
      # after. `read` takes the same locks for that reason.
      #
      # Locks are keyed by stored tags — digests for hashed ones — so no
      # plaintext value of a hashed tag is sent with them.
      protected def append_batch(events : Array(ES::Event), condition : ES::AppendCondition?) : Int64
        encoded = encode_events(events)
        items = condition.try { |cond| encode_query(cond.fail_if_events_match) }
        position = 0_i64

        locked_transaction(lock_plan(encoded, items)) do |connection|
          if condition && items
            args = [] of DB::Any | Array(String)
            sql = "SELECT EXISTS (SELECT 1 FROM \"eventstore\".\"events\" WHERE #{query_condition(items, args)}"
            if after = condition.after
              args << after
              sql += %( AND id > $#{args.size})
            end
            sql += ")"

            raise append_conflict(condition) if connection.query_one(sql, args: args, as: Bool)
          end

          encoded.each do |event|
            position = connection.query_one(
              %(INSERT INTO "eventstore"."events" (header, body) VALUES ($1, $2) RETURNING id::BIGINT),
              event.header, event.body, as: Int64
            )
          end
        end

        position
      end

      # Runs the block in a READ COMMITTED transaction holding the given locks.
      #
      # All locks are taken by one statement, in the order given — `unnest` over
      # a function scan yields the arrays in order, and no sort runs in between.
      private def locked_transaction(plan : Array({Int32, Bool}), &)
        keys = plan.map(&.[0])
        exclusive = plan.map(&.[1])

        @db.transaction do |tx|
          connection = tx.connection
          connection.exec %(SET TRANSACTION ISOLATION LEVEL READ COMMITTED)
          connection.exec(
            %(SELECT CASE WHEN t.exclusive THEN pg_advisory_xact_lock($1, t.key) ELSE pg_advisory_xact_lock_shared($1, t.key) END FROM unnest($2::int4[], $3::bool[]) AS t(key, exclusive)),
            LOCK_NAMESPACE, keys, exclusive
          )
          yield connection
        end
      end

      # The advisory locks to take, as `{key, exclusive}` sorted by key so two
      # transactions can never wait on each other's locks in a cycle.
      #
      # Every append takes a shared lock on each tag and the type of every event
      # it writes, plus one store-wide key. A condition — or a read — then only
      # needs one exclusive lock per query item, on something every matching
      # event's writer holds shared: one of the item's tags if it has any — an
      # event matching the item carries all of them — else each of its types,
      # else the store-wide key. It also takes the store-wide key shared, which
      # is what a batch past `MAX_LOCK_KEYS` locks exclusively instead of its
      # tags and types. Where a key is needed both ways, exclusive wins.
      #
      # Keys are 32-bit digests; two names sharing one only serialize appends
      # that did not need to be, they never let a conflict through.
      private def lock_plan(encoded : Array(EncodedEvent), items : Array(EncodedQueryItem)?) : Array({Int32, Bool})
        modes = Hash(Int32, Bool).new

        names = Set(String).new
        encoded.each do |event|
          names << "handle:#{event.handle}"
          event.tags.each { |tag| names << "tag:#{tag}" }
        end

        if names.size > MAX_LOCK_KEYS
          lock(modes, "*", exclusive: true)
        else
          lock(modes, "*", exclusive: false)
          names.each { |name| lock(modes, name, exclusive: false) }
        end

        items.try &.each do |item|
          lock(modes, "*", exclusive: false)

          if tag = item.tags.min?
            lock(modes, "tag:#{tag}", exclusive: true)
          elsif !item.types.empty?
            item.types.each { |type| lock(modes, "handle:#{type}", exclusive: true) }
          else
            lock(modes, "*", exclusive: true)
          end
        end

        modes.to_a.sort_by!(&.[0])
      end

      private def lock(modes : Hash(Int32, Bool), name : String, exclusive : Bool)
        key = self.class.lock_key(name)
        modes[key] = exclusive || modes.fetch(key, false)
      end

      # The advisory lock key for a lock name — `"*"`, `"handle:<event handle>"`
      # or `"tag:<stored tag>"` — taken under `LOCK_NAMESPACE`. Public because
      # the locks are a protocol: anything else writing to the events table has
      # to take them the same way for conditional appends to stay correct.
      def self.lock_key(name : String) : Int32
        IO::ByteFormat::BigEndian.decode(Int32, Digest::SHA256.digest(name)[0, 4])
      end

      # Returns a single event for a given id
      def fetch_event(event_id : UUID) : ES::EventStore::Event
        header, body = @db.query_one %(SELECT header, body FROM "eventstore"."events" WHERE header->>'event_id'=$1), event_id, as: {JSON::Any, JSON::Any}
        decode(header, body)
      rescue DB::NoResultsError
        raise ES::Exception::NotFound.new("Event '#{event_id}' not found in eventstore")
      end

      # Streams all events in global chronological order via cursor-based pagination
      def each_event(until_event_id : UUID? = nil, batch_size : Int64 = 1000, &block : ES::EventStore::Event ->)
        if uid = until_event_id
          exists = @db.query_one?(
            %((SELECT (header->>'event_id')::uuid FROM "eventstore"."events" WHERE header->>'event_id' = $1)),
            uid, as: UUID
          )
          raise ES::Exception::NotFound.new("Event '#{uid}' not found in eventstore") if exists.nil?
        end

        cursor = 0_i64
        loop do
          rows = if uid = until_event_id
                   @db.query_all(
                     %(SELECT id::BIGINT, header, body FROM "eventstore"."events" WHERE id > $1 AND id <= (SELECT id FROM "eventstore"."events" WHERE header->>'event_id' = $2) ORDER BY id ASC LIMIT $3),
                     cursor, uid.to_s, batch_size, as: {Int64, JSON::Any, JSON::Any}
                   )
                 else
                   @db.query_all(
                     %(SELECT id::BIGINT, header, body FROM "eventstore"."events" WHERE id > $1 ORDER BY id ASC LIMIT $2),
                     cursor, batch_size, as: {Int64, JSON::Any, JSON::Any}
                   )
                 end

          break if rows.empty?

          rows.each do |id, header, body|
            if es_event = decode_or_skip(header, body)
              block.call(es_event)
            end
            cursor = id
          end

          break if rows.size < batch_size
        end
      end

      # Returns the event_id of the most recently appended event, or nil if the store is empty
      def last_event_id : UUID?
        result = @db.query_one?(
          %(SELECT header->>'event_id' FROM "eventstore"."events" ORDER BY id DESC LIMIT 1),
          as: String
        )
        result ? UUID.new(result) : nil
      end

      # Returns the encryption keys used across an aggregate's stream
      def encryption_key_ids(aggregate_id : UUID) : Array(UUID)
        @db.query_all(
          %(SELECT DISTINCT header->>'encryption_key_id' FROM "eventstore"."events" WHERE header->>'aggregate_id' = $1 AND header->>'encryption_key_id' IS NOT NULL),
          aggregate_id, as: String
        ).map { |id| UUID.new(id) }
      end

      # Returns the events matching a query, in append order
      def read(query : ES::Query, after : Int64? = nil, limit : Int32? = nil) : Array(ES::EventStore::Event)
        validate_read_options(after, limit)
        args = [] of DB::Any | Array(String)

        items = encode_query(query)
        sql = %(SELECT id::BIGINT, header, body FROM "eventstore"."events" WHERE #{query_condition(items, args)})
        if a = after
          args << a
          sql += %( AND id > $#{args.size})
        end
        sql += %( ORDER BY id ASC)
        if l = limit
          args << l.to_i64
          sql += %( LIMIT $#{args.size})
        end

        # Read under the locks a conditional append on this query takes. Until
        # the locks are granted, a matching append may be in flight with a
        # position below one that already committed; once they are, none can be,
        # and every later one gets a higher position than anything this returns.
        # So `after: <last position read>` cannot skip an event the read missed.
        # The SELECT has to run while the locks are held — released any earlier,
        # a new append could take a lower position than one committing before the
        # SELECT starts.
        rows = [] of {Int64, JSON::Any, JSON::Any}
        locked_transaction(lock_plan([] of EncodedEvent, items)) do |connection|
          rows = connection.query_all(sql, args: args, as: {Int64, JSON::Any, JSON::Any})
        end

        rows.map { |id, header, body| decode_or_erase(header, body, id) }
      end

      # Builds the WHERE condition for an encoded query, appending its parameters
      # to `args`. Only fixed SQL and `$n` placeholders end up in the string; every
      # value travels as a parameter.
      protected def query_condition(items : Array(EncodedQueryItem), args : Array(DB::Any | Array(String))) : String
        clauses = items.map do |item|
          parts = [] of String

          unless item.types.empty?
            args << item.types
            parts << %(header->>'event_handle' = ANY($#{args.size}::text[]))
          end

          unless item.tags.empty?
            args << item.tags.to_json
            parts << %(header->'tags' @> $#{args.size}::jsonb)
          end

          parts.empty? ? "TRUE" : "(#{parts.join(" AND ")})"
        end

        "(#{clauses.join(" OR ")})"
      end

      # Returns the stream of events for a given aggregate
      def fetch_events(aggregate_id : UUID) : Array(ES::EventStore::Event)
        event_array = Array(ES::EventStore::Event).new

        prepared_statement = @db.build(%(SELECT header, body FROM "eventstore"."events" WHERE header->>'aggregate_id'=$1 ORDER BY (header->>'aggregate_version')::INT ASC))

        prepared_statement.query(aggregate_id) do |result|
          result.each do
            event_array << decode(result.read(JSON::Any), result.read(JSON::Any))
          end
        end

        event_array
      end
    end
  end
end
