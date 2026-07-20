module ES
  module EventStoreAdapters
    class Postgres < ES::EventStore
      # Initialize with a database connection
      def initialize(@db : DB::Database)
      end

      # Initializes the database with the necessary schema, table and permissions for the eventstore
      def setup
        m = Array(String).new
        m << %( CREATE SCHEMA IF NOT EXISTS "eventstore"; )
        m << %( GRANT USAGE ON SCHEMA "eventstore" TO pg_monitor; )
        m << %( GRANT SELECT ON ALL TABLES IN SCHEMA "eventstore" TO pg_monitor; )
        m << %( GRANT SELECT ON ALL SEQUENCES IN SCHEMA "eventstore" TO pg_monitor; )
        m << %( ALTER DEFAULT PRIVILEGES IN SCHEMA "eventstore" GRANT SELECT ON TABLES TO pg_monitor; )
        m << %( ALTER DEFAULT PRIVILEGES IN SCHEMA "eventstore" GRANT SELECT ON SEQUENCES TO pg_monitor; )
        m << %(
          CREATE TABLE IF NOT EXISTS "eventstore"."events" (
            "id" BIGSERIAL PRIMARY KEY,
            "header" jsonb NOT NULL,
            "body" jsonb NOT NULL
          );
        )

        m << %(CREATE UNIQUE INDEX IF NOT EXISTS aggregate_id_version_idx ON "eventstore"."events"((header->>'aggregate_id'), (header->>'aggregate_version'));)

        # Sequence memberships of every event: the primary aggregate plus any tags.
        # The primary key enforces per-sequence version uniqueness as a backstop for
        # the conditional append.
        m << %(
          CREATE TABLE IF NOT EXISTS "eventstore"."event_tags" (
            "tag"         TEXT   NOT NULL,
            "tag_version" INT    NOT NULL,
            "event_id"    BIGINT NOT NULL REFERENCES "eventstore"."events"("id") ON DELETE CASCADE,
            PRIMARY KEY ("tag", "tag_version")
          );
        )
        m << %(CREATE INDEX IF NOT EXISTS event_tags_event_id_idx ON "eventstore"."event_tags"("event_id");)

        # Backfill primary-aggregate memberships for events appended before the
        # event_tags table existed (idempotent)
        m << %(
          INSERT INTO "eventstore"."event_tags" (tag, tag_version, event_id)
          SELECT e.header->>'aggregate_id', (e.header->>'aggregate_version')::INT, e.id
          FROM "eventstore"."events" e
          ON CONFLICT DO NOTHING;
        )

        m << %(
          CREATE OR REPLACE VIEW "eventstore"."eventstore_flattened"
          AS
          SELECT
            e.id,
            e.header ->> 'aggregate_id' AS "aggregate_id",
            e.header ->> 'event_handle' AS "event_handle",
            e.header ->> 'aggregate_version' AS "aggregate_version",
            e.header ->> 'aggregate_type' AS "aggregate_type",
            e.header -> 'tags' AS "tags",
            e.header,
            e.body
          FROM
            "eventstore"."events" e
          ORDER BY
            id ASC,
            e.header ->> 'aggregate_id' ASC,
            e.header ->> 'aggregate_version' ASC;
        )

        m.each { |s| @db.exec s }
      end

      # Atomically appends a batch of events, guarded by an append condition.
      #
      # All sequence keys involved (condition members and written sequences) are
      # serialized via transaction-scoped advisory locks, acquired in sorted order to
      # avoid deadlocks. Under those locks the current version of every sequence is
      # validated against the condition and the staged versions, so read-only boundary
      # members are race-free without SERIALIZABLE isolation.
      def append(events : Array(ES::Event), condition : ES::AppendCondition = ES::AppendCondition.none)
        written = Hash(String, Array(Int32)).new { |hash, key| hash[key] = Array(Int32).new }
        events.each do |event|
          event.memberships.each { |key, version| written[key] << version }
        end

        keys = (condition.expected.keys + written.keys).uniq.sort

        @db.transaction do |tx|
          cnn = tx.connection

          keys.each do |key|
            cnn.exec %(SELECT pg_advisory_xact_lock(hashtextextended($1, 0))), key
          end

          keys.each do |key|
            actual = cnn.query_one %(SELECT COALESCE(MAX(tag_version), 0)::INT FROM "eventstore"."event_tags" WHERE tag = $1), key, as: Int32

            if expected = condition.expected[key]?
              raise ES::Exception::Conflict.new("Sequence '#{key}' is at version '#{actual}', expected version '#{expected}'") if actual != expected
            end

            if staged = written[key]?
              staged.sort!
              expected_range = ((actual + 1)..(actual + staged.size)).to_a
              raise ES::Exception::Conflict.new("Non-contiguous versions for sequence '#{key}': provided versions '#{staged}', current version '#{actual}'") if staged != expected_range
            end
          end

          events.each do |event|
            row_id = cnn.query_one %(INSERT INTO "eventstore"."events" (header, body) VALUES ($1, $2) RETURNING id), event.header.to_json, event.body.to_json, as: Int64

            event.memberships.each do |tag, version|
              cnn.exec %(INSERT INTO "eventstore"."event_tags" (tag, tag_version, event_id) VALUES ($1, $2, $3)), tag, version, row_id
            end
          end
        end
      rescue ex : ES::Exception::Error
        raise ex
      rescue ex
        # Backstop: translate unique violations (SQLSTATE 23505) raised by the events
        # or event_tags constraints into a Conflict
        raise ES::Exception::Conflict.new("Concurrent append detected: #{ex.message}") if ex.message.try(&.matches?(/23505|duplicate key/))
        raise ex
      end

      # Returns a single event for a given id
      def fetch_event(event_id : UUID) : ES::EventStore::Event
        header, body = @db.query_one %(SELECT header, body FROM "eventstore"."events" WHERE header->>'event_id'=$1), event_id, as: {JSON::Any, JSON::Any}
        ES::EventStore::Event.new(header, body)
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
            block.call(ES::EventStore::Event.new(header, body))
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

      # Returns the last version of the given sequence (aggregate_id or tag), 0 if empty
      def last_version(sequence_key : String) : Int32
        @db.query_one %(SELECT COALESCE(MAX(tag_version), 0)::INT FROM "eventstore"."event_tags" WHERE tag = $1), sequence_key, as: Int32
      end

      # Returns the stream of events for a given aggregate
      def fetch_events(aggregate_id : UUID) : Array(ES::EventStore::Event)
        event_array = Array(ES::EventStore::Event).new

        prepared_statement = @db.build(%(SELECT header, body FROM "eventstore"."events" WHERE header->>'aggregate_id'=$1 ORDER BY (header->>'aggregate_version')::INT ASC))

        prepared_statement.query(aggregate_id) do |result|
          result.each do
            event_array << ES::EventStore::Event.new(result.read(JSON::Any), result.read(JSON::Any))
          end
        end

        event_array
      end

      # Returns the stream of events for a given sequence key (aggregate_id or tag), ordered by that sequence's version
      def fetch_events(tag : String) : Array(ES::EventStore::Event)
        event_array = Array(ES::EventStore::Event).new

        prepared_statement = @db.build(%(SELECT e.header, e.body FROM "eventstore"."events" e JOIN "eventstore"."event_tags" t ON t.event_id = e.id WHERE t.tag = $1 ORDER BY t.tag_version ASC))

        prepared_statement.query(tag) do |result|
          result.each do
            event_array << ES::EventStore::Event.new(result.read(JSON::Any), result.read(JSON::Any))
          end
        end

        event_array
      end
    end
  end
end
