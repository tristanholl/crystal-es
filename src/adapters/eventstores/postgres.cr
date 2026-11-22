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

      # The current version of every stored tag: how many events carrying it were
      # appended. Every tagged append raises it under the row lock, which is what
      # serializes appends carrying the same tag and what conditional appends
      # compare against. One row per distinct tag value; rows are never deleted.
      TAG_VERSIONS_TABLE = %(CREATE TABLE IF NOT EXISTS "eventstore"."tag_versions" ("tag" TEXT PRIMARY KEY, "version" BIGINT NOT NULL);)

      # The indexes `setup` adds to a store created before they existed, by name
      private EXISTING_STORE_INDEXES = {
        "events_event_id_idx"     => EVENT_ID_INDEX,
        "events_tags_idx"         => TAGS_INDEX,
        "events_event_handle_idx" => EVENT_HANDLE_INDEX,
      }

      # Session advisory lock that lets one `setup` of an existing store run at a time
      private SETUP_LOCK = 0x6372_7973_6573_6978_i64

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
          # Concurrent DDL on the same objects fails ("tuple concurrently
          # updated"), so setups running at the same time take turns
          with_setup_lock do |connection|
            connection.exec TAG_VERSIONS_TABLE
            # Default privileges only cover tables created by the role that set
            # them, which need not be the one running this setup
            connection.exec %(GRANT SELECT ON "eventstore"."tag_versions" TO pg_monitor;)
            build_missing_indexes(connection)
          end
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
        migrations << TAG_VERSIONS_TABLE

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

      # Holds the setup lock on one connection while the block runs, and runs
      # every statement of the block on it, so setup needs one connection only.
      # The lock is a session lock, which needs a session-mode connection, not
      # one through a transaction-mode pooler.
      #
      # It is polled rather than waited on: a session waiting on a lock is in a
      # transaction, which a concurrent index build in the lock holder has to
      # wait for in turn. There is no time limit, since a legitimate holder may
      # be building an index for a long time; the wait is logged instead.
      private def with_setup_lock(&)
        @db.using_connection do |connection|
          polls = 0
          until connection.query_one(%(SELECT pg_try_advisory_lock($1)), SETUP_LOCK, as: Bool)
            if polls % 30 == 0
              holders = connection.query_all(%(SELECT pid FROM pg_locks WHERE locktype = 'advisory' AND granted AND database = (SELECT oid FROM pg_database WHERE datname = current_database()) AND objsubid = 1 AND ((classid::int8 << 32) | objid::int8) = $1), SETUP_LOCK, as: Int32)
              Log.warn { "Waiting for another session to finish setting up the event store: advisory lock #{SETUP_LOCK} held by backend #{holders.join(", ")}" }
            end
            polls += 1
            sleep 1.second
          end

          begin
            yield connection
          ensure
            connection.exec %(SELECT pg_advisory_unlock($1)), SETUP_LOCK
          end
        end
      end

      # Stores created before an index existed get it on their next setup. The
      # build runs CONCURRENTLY, so appends go on while it scans the table, and
      # setup returns once it is done. The event_id one fails if the store holds
      # duplicate event ids, which should never happen.
      #
      # Only missing indexes are built: a concurrent build deadlocks with one
      # already running on the same table, even when its own index exists.
      private def build_missing_indexes(connection : DB::Connection)
        rebuild_invalid_indexes(connection)
        existing = index_names(connection)
        EXISTING_STORE_INDEXES.each do |name, statement|
          next if existing.includes?(name)

          if existing.includes?(rebuild_name(name))
            # A rebuild that stopped between dropping the old index and renaming
            # the new one, which is valid: invalid leftovers were dropped above
            connection.exec %(ALTER INDEX "eventstore"."#{rebuild_name(name)}" RENAME TO "#{name}")
          else
            connection.exec concurrently(statement)
          end
        end
      end

      # Plain CREATE INDEX blocks writes to the table for the whole build. The
      # public constants keep the plain form, which is what a new, empty store
      # uses and what applications may already run themselves.
      private def concurrently(statement : String) : String
        concurrent = statement.sub(" INDEX IF NOT EXISTS ", " INDEX CONCURRENTLY IF NOT EXISTS ")
        # Falling back to the plain form would block appends without a word
        raise ES::Exception::InvalidState.new("Index statement cannot be made concurrent: #{statement}") if concurrent == statement
        concurrent
      end

      private def rebuild_name(name : String) : String
        "#{name}_rebuild"
      end

      # A CREATE INDEX CONCURRENTLY that failed leaves an invalid index behind,
      # which would otherwise count as existing. An index of this store's own
      # that is invalid is built again under a temporary name, and swaps places
      # with the invalid one once valid. The invalid one may still enforce
      # uniqueness, so dropping it first would let a repeated event id in.
      #
      # A build still running looks the same, so nothing happens while any
      # concurrent index build might be running on the events table: rebuilding
      # would deadlock with it. A build by another role shows no table, so it
      # counts as one on the events table. The index is then left alone and
      # `warn_about_invalid_indexes` reports it.
      #
      # Names in the DDL below come from EXISTING_STORE_INDEXES, never from input.
      private def rebuild_invalid_indexes(connection : DB::Connection)
        invalid = invalid_index_names(connection)
        abandoned = invalid & EXISTING_STORE_INDEXES.keys
        leftovers = invalid & EXISTING_STORE_INDEXES.keys.map { |name| rebuild_name(name) }
        return if abandoned.empty? && leftovers.empty?
        return if index_build_running?(connection)

        leftovers.each do |name|
          connection.exec %(DROP INDEX CONCURRENTLY IF EXISTS "eventstore"."#{name}")
        end

        abandoned.each do |name|
          Log.warn { "Index 'eventstore.#{name}' is invalid, left by a failed concurrent build. Building it again." }
          temporary = rebuild_name(name)
          renamed = concurrently(EXISTING_STORE_INDEXES[name]).sub(" #{name} ON ", " #{temporary} ON ")
          raise ES::Exception::InvalidState.new("Index statement cannot be renamed: #{name}") if renamed.includes?(" #{name} ON ")
          connection.exec renamed
          connection.exec %(DROP INDEX CONCURRENTLY IF EXISTS "eventstore"."#{name}")
          connection.exec %(ALTER INDEX "eventstore"."#{temporary}" RENAME TO "#{name}")
        end
      end

      # Builds can only be seen from Postgres 12 on. Before that, one might
      # always be running.
      private def index_build_running?(connection : DB::Connection) : Bool
        return true if connection.query_one(%(SELECT current_setting('server_version_num')::int), as: Int32) < 120000

        connection.query_one(
          %(SELECT EXISTS (SELECT FROM pg_stat_progress_create_index WHERE datname = current_database() AND (relid IS NULL OR relid = '"eventstore"."events"'::regclass))),
          as: Bool
        )
      end

      private def index_names(connection : DB::Connection) : Array(String)
        connection.query_all(
          %(SELECT c.relname FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'eventstore'),
          as: String
        )
      end

      private def invalid_index_names(connection : DB::Connection | DB::Database) : Array(String)
        connection.query_all(
          %(SELECT c.relname FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'eventstore' AND NOT i.indisvalid ORDER BY c.relname),
          as: String
        )
      end

      # An invalid index is not used by queries, so one that setup could not
      # rebuild is reported rather than passed over in silence
      private def warn_about_invalid_indexes
        invalid_index_names(@db).each do |name|
          Log.warn { "Index 'eventstore.#{name}' is invalid and not used by queries: a CREATE INDEX CONCURRENTLY is still running or has failed. Once no build is running, setup rebuilds the indexes it owns; drop any other one yourself." }
        end
      end

      # Appends an event to the event stream and returns its position
      def append(event : ES::Event)
        append_batch([event.as(ES::Event)], nil)
      end

      # Appends a batch atomically, failing with `ES::Exception::Conflict` if a
      # tag the condition names is no longer at the expected version.
      #
      # In one READ COMMITTED transaction:
      #
      # 1. Lock the version row of every tag the batch carries or the condition
      #    names — created at version 0 where missing — in one statement, in tag
      #    order, so two appends can never wait on each other in a cycle. An
      #    append carrying a tag that another append is still writing waits for
      #    it to commit and then sees its version.
      # 2. Compare the condition's expected versions with the locked ones.
      # 3. Assign each event its tag versions, stamp them into its header, insert
      #    it, and store the raised versions.
      #
      # Versions of one tag therefore follow commit order without gaps, whatever
      # positions the events get. Untagged events with no condition lock nothing.
      protected def append_batch(events : Array(ES::Event), condition : ES::AppendCondition?) : Int64
        encoded = encode_events(events)
        expected = condition.try { |cond| expected_versions(cond) } || {} of String => Int64
        tags = (encoded.flat_map(&.tags) + expected.keys).uniq.sort!
        position = 0_i64

        @db.transaction do |tx|
          connection = tx.connection
          connection.exec %(SET TRANSACTION ISOLATION LEVEL READ COMMITTED)

          current = {} of String => Int64
          unless tags.empty?
            # The no-op update is what takes the row lock on an existing row
            connection.query_all(
              %(INSERT INTO "eventstore"."tag_versions" AS t (tag, version) SELECT tag, 0 FROM unnest($1::text[]) AS tag ORDER BY tag ON CONFLICT (tag) DO UPDATE SET version = t.version RETURNING tag, version),
              tags, as: {String, Int64}
            ).each { |tag, version| current[tag] = version }
          end

          if mismatch = version_mismatch(expected, current)
            raise append_conflict(mismatch)
          end

          versions = assign_versions(encoded, current)
          encoded.each_with_index do |event, index|
            position = connection.query_one(
              %(INSERT INTO "eventstore"."events" (header, body) VALUES ($1, $2) RETURNING id::BIGINT),
              stored_header(event, versions[index]), event.body, as: Int64
            )
          end

          raised = encoded.flat_map(&.tags).uniq!
          unless raised.empty?
            connection.exec(
              %(UPDATE "eventstore"."tag_versions" AS t SET version = v.version FROM unnest($1::text[], $2::int8[]) AS v(tag, version) WHERE t.tag = v.tag),
              raised, raised.map { |tag| current[tag] }
            )
          end
        end

        position
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

        @db.query_all(sql, args: args, as: {Int64, JSON::Any, JSON::Any}).map do |id, header, body|
          decode_or_erase(header, body, id)
        end
      end

      # Returns the events matching a query and the current versions of its
      # tags, read in one REPEATABLE READ snapshot. A writer commits its events
      # and its version raises together, so the two always agree: no event the
      # read missed can be hidden behind a version it saw. Takes no locks.
      def read_for_decision(query : ES::Query) : ES::Decision
        items = encode_query(query)
        tags = decision_tags(items)
        args = [] of DB::Any | Array(String)
        sql = %(SELECT id::BIGINT, header, body FROM "eventstore"."events" WHERE #{query_condition(items, args)} ORDER BY id ASC)

        rows = [] of {Int64, JSON::Any, JSON::Any}
        versions = tags.to_h { |tag| {tag, 0_i64} }
        @db.transaction do |tx|
          connection = tx.connection
          connection.exec %(SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY)
          rows = connection.query_all(sql, args: args, as: {Int64, JSON::Any, JSON::Any})
          connection.query_all(
            %(SELECT tag, version FROM "eventstore"."tag_versions" WHERE tag = ANY($1::text[])),
            tags, as: {String, Int64}
          ).each { |tag, version| versions[tag] = version }
        end

        ES::Decision.new(rows.map { |id, header, body| decode_or_erase(header, body, id) }, versions)
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
