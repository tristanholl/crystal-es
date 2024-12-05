module ES
  module EventStoreAdapters
    class Postgres < ES::EventStore
      # Initialize with a database connection
      def initialize(@db : DB::Database)
      end

      # Initializes the database with the necessary schema, table and permissions for the eventstore
      def setup
        skip = @db.query_one %(SELECT EXISTS (SELECT FROM pg_tables WHERE  schemaname = 'eventstore' AND tablename  = 'events');), as: Bool
        return true if skip

        m = Array(String).new
        m << %( CREATE SCHEMA IF NOT EXISTS "eventstore"; )
        m << %( GRANT USAGE ON SCHEMA "eventstore" TO pg_monitor; )
        m << %( GRANT SELECT ON ALL TABLES IN SCHEMA "eventstore" TO pg_monitor; )
        m << %( GRANT SELECT ON ALL SEQUENCES IN SCHEMA "eventstore" TO pg_monitor; )
        m << %( ALTER DEFAULT PRIVILEGES IN SCHEMA "eventstore" GRANT SELECT ON TABLES TO pg_monitor; )
        m << %( ALTER DEFAULT PRIVILEGES IN SCHEMA "eventstore" GRANT SELECT ON SEQUENCES TO pg_monitor; )
        m << %(
          CREATE TABLE "eventstore"."events" (
            "id" SERIAL PRIMARY KEY,
            "header" jsonb NOT NULL,
            "body" jsonb NOT NULL
          );
        )

        m << %(CREATE UNIQUE INDEX aggregate_id_version_idx ON "eventstore"."events"((header->>'aggregate_id'), (header->>'aggregate_version'));)

        m << %(
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

        m.each { |s| @db.exec s }
      end

      # Appends an event to the event stream
      def append(event : ES::Event)
        @db.exec %(INSERT INTO "eventstore"."events" (header, body) VALUES ($1, $2)), event.header.to_json, event.body.to_json
      end

      # Returns a single event for a given id
      def fetch_event(event_id : UUID) : ES::EventStore::Event
        header, body = @db.query_one %(SELECT header, body FROM "eventstore"."events" WHERE header->>'event_id'=$1), event_id, as: {JSON::Any, JSON::Any}
        ES::EventStore::Event.new(header, body)
      rescue DB::NoResultsError
        raise ES::Exception::NotFound.new("Event '#{event_id}' not found in eventstore")
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
    end
  end
end
