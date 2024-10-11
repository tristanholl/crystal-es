module ES
  module QueueAdapters
    class Postgres < ES::Queue
      # Initialize the postgres queue with a database connection
      def initialize(@db : DB::Database)
      end

      # Prepares the data for queue usage
      def setup
        skip = @db.query_one %(SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgmq')), as: Bool
        return true if skip

        m = Array(String).new
        m << %( CREATE EXTENSION pgmq cascade; )
        m << %( DROP TRIGGER IF EXISTS "queue_event" ON "eventstore"."events"; )
        m << %( DROP FUNCTION IF EXISTS "eventstore"."queue_event" CASCADE; )
        m << %( SELECT FROM "pgmq"."create"('eventstore_queue'); )
        m << %(
          CREATE OR REPLACE FUNCTION "eventstore"."queue_event" ()
            RETURNS TRIGGER
            AS $trigger$
          BEGIN
            PERFORM "pgmq".send('eventstore_queue', NEW.header);

            RETURN NEW;
          END;
          $trigger$
          LANGUAGE plpgsql;
        )
        m << %(
          CREATE OR REPLACE TRIGGER "queue_event"
            AFTER INSERT
            ON "eventstore"."events"
          FOR EACH ROW
              EXECUTE PROCEDURE "eventstore"."queue_event"();
        )

        m.each { |s| @db.exec s }
      end

      # Archives a message from the queue
      def archive(name : String, msg_id : Int64)
        @db.query_one %(SELECT * FROM "pgmq"."archive"('#{name}', #{msg_id})), as: {Bool}
      end

      # Deletes a message from the queue
      def delete(name : String, msg_id : Int64)
        @db.query_one %(SELECT * FROM "pgmq"."delete"('#{name}', #{msg_id})), as: {Bool}
      end

      # Reads messages from the queue
      protected def read(name : String, timeout = 10, count = 1) : Array(ES::Queue::Entry)
        message_array = Array(ES::Queue::Entry).new

        prepared_statement = @db.build(%(SELECT msg_id, read_ct, message FROM "pgmq"."read"($1, $2, $3)))
        prepared_statement.query(name, timeout, count) do |result|
          result.each do
            message_array << ES::Queue::Entry.new(result.read(Int64), result.read(Int32), result.read(JSON::Any))
          end
        end

        message_array
      end
    end
  end
end
