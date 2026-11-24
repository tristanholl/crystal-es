module ES
  module SubscriptionStoreAdapters
    # Subscription state in the event store's database, schema `eventstore`:
    #
    # - `subscriptions`: position and status per subscription
    # - `subscription_instances`: a heartbeat per running instance, so they can
    #   share the subscriptions out evenly
    #
    # Locks are session advisory locks, held on one connection taken out of
    # the pool for as long as the store lives. They need a session-mode
    # connection, not one through a pooler in transaction mode (PgBouncer
    # `pool_mode = transaction`). An instance that dies loses its connection,
    # and Postgres releases its locks with it.
    #
    # With `listen_url`, the store LISTENs for the notification a trigger on
    # the events table sends on every append, and wakes subscriptions at once
    # instead of at their next poll. This needs crystal-pg (`require "pg"`).
    # The trigger is only installed by a `setup` that listens: Postgres
    # commits transactions that sent a notification one at a time, so it
    # costs every writer of the store some append throughput. Without it,
    # subscriptions pick new events up at their next poll.
    class Postgres < ES::SubscriptionStore
      # The channel the events trigger notifies
      NOTIFY_CHANNEL = "crystal_es_events"

      # Transaction advisory lock that lets one `setup` run at a time
      private SETUP_LOCK = 0x6372_7973_6573_7375_i64

      # Prefix of the advisory lock keys, so they don't collide with an
      # application's own advisory locks by accident
      private LOCK_PREFIX = "crystal-es:subscription:"

      private SUBSCRIPTIONS_TABLE = <<-SQL
        CREATE TABLE IF NOT EXISTS "eventstore"."subscriptions" (
          "name" TEXT PRIMARY KEY,
          "position_transaction_id" BIGINT NOT NULL,
          "position_id" BIGINT NOT NULL,
          "status" TEXT NOT NULL DEFAULT 'running',
          "attempts" INTEGER NOT NULL DEFAULT 0,
          "last_error" TEXT,
          "failed_transaction_id" BIGINT,
          "failed_id" BIGINT,
          "updated_at" TIMESTAMPTZ NOT NULL DEFAULT now()
        )
        SQL

      private INSTANCES_TABLE = <<-SQL
        CREATE TABLE IF NOT EXISTS "eventstore"."subscription_instances" (
          "instance_id" TEXT PRIMARY KEY,
          "heartbeat_at" TIMESTAMPTZ NOT NULL
        )
        SQL

      private NOTIFY_FUNCTION = <<-SQL
        CREATE OR REPLACE FUNCTION "eventstore"."notify_subscriptions"() RETURNS trigger AS $$
        BEGIN
          PERFORM pg_notify('#{NOTIFY_CHANNEL}', '');
          RETURN NULL;
        END
        $$ LANGUAGE plpgsql
        SQL

      # Per statement, and Postgres folds identical notifications of one
      # transaction into one, so a batch append wakes subscribers once
      private NOTIFY_TRIGGER = %(CREATE TRIGGER "notify_subscriptions" AFTER INSERT ON "eventstore"."events" FOR EACH STATEMENT EXECUTE PROCEDURE "eventstore"."notify_subscriptions"())

      private STATE_COLUMNS = %(name, position_transaction_id, position_id, status, attempts, last_error, failed_transaction_id, failed_id, updated_at)

      @lock_connection : DB::Connection? = nil
      @lock_mutex = Mutex.new
      @locks_lost = false
      @wakeups = Channel(Nil).new(1)
      @stop_listening : Proc(Nil)? = nil

      def initialize(@db : DB::Database, listen_url : String? = nil)
        listen(listen_url) if listen_url
      end

      # Creates the tables, and the notification trigger when listening.
      # Idempotent; the event store must be set up first. Drop the trigger
      # (`DROP TRIGGER notify_subscriptions ON eventstore.events`) once no
      # instance listens any more.
      def setup : Nil
        @db.transaction do |tx|
          connection = tx.connection
          # Concurrent DDL on the same objects fails, so setups take turns
          connection.exec %(SELECT pg_advisory_xact_lock($1)), SETUP_LOCK
          connection.exec SUBSCRIPTIONS_TABLE
          connection.exec INSTANCES_TABLE
          connection.exec %(GRANT SELECT ON "eventstore"."subscriptions", "eventstore"."subscription_instances" TO pg_monitor)
          if @stop_listening
            connection.exec NOTIFY_FUNCTION
            trigger = connection.query_one(%(SELECT EXISTS (SELECT FROM pg_trigger WHERE tgname = 'notify_subscriptions' AND tgrelid = '"eventstore"."events"'::regclass)), as: Bool)
            # Only when missing: creating it locks the events table against appends
            connection.exec NOTIFY_TRIGGER unless trigger
          end
        end
      end

      def fetch(name : String) : State?
        states(%(SELECT #{STATE_COLUMNS} FROM "eventstore"."subscriptions" WHERE name = $1), [name] of DB::Any).first?
      end

      def all : Array(State)
        states(%(SELECT #{STATE_COLUMNS} FROM "eventstore"."subscriptions" ORDER BY name), [] of DB::Any)
      end

      def create(name : String, position : ES::EventStore::LogPosition) : Nil
        @db.exec(
          %(INSERT INTO "eventstore"."subscriptions" (name, position_transaction_id, position_id) VALUES ($1, $2, $3) ON CONFLICT (name) DO NOTHING),
          name, position.transaction_id, position.id
        )
      end

      def advance(name : String, expected : ES::EventStore::LogPosition, position : ES::EventStore::LogPosition, within : ES::EventStore) : Nil
        bound = within.as?(ES::EventStoreAdapters::Postgres::Bound)
        raise ES::Exception::InvalidState.new("advance needs a store yielded by a Postgres event store's transaction") if bound.nil?

        moved = move(bound.connection, name, expected, position)
        raise ES::Exception::StaleCheckpoint.new("Subscription '#{name}' is no longer at #{expected}") unless moved
      end

      def advance(name : String, expected : ES::EventStore::LogPosition, position : ES::EventStore::LogPosition) : Bool
        move(@db, name, expected, position)
      end

      def record_position(name : String, position : ES::EventStore::LogPosition) : Nil
        @db.exec(
          %(INSERT INTO "eventstore"."subscriptions" (name, position_transaction_id, position_id) VALUES ($1, $2, $3) ON CONFLICT (name) DO UPDATE SET position_transaction_id = EXCLUDED.position_transaction_id, position_id = EXCLUDED.position_id, updated_at = now()),
          name, position.transaction_id, position.id
        )
      end

      def reset(name : String, position : ES::EventStore::LogPosition) : Nil
        @db.exec(
          %(INSERT INTO "eventstore"."subscriptions" (name, position_transaction_id, position_id) VALUES ($1, $2, $3) ON CONFLICT (name) DO UPDATE SET position_transaction_id = EXCLUDED.position_transaction_id, position_id = EXCLUDED.position_id, status = 'running', attempts = 0, last_error = NULL, failed_transaction_id = NULL, failed_id = NULL, updated_at = now()),
          name, position.transaction_id, position.id
        )
      end

      def record_failure(name : String, attempts : Int32, message : String, failed_position : ES::EventStore::LogPosition, status : String) : Nil
        @db.exec(
          %(UPDATE "eventstore"."subscriptions" SET status = $2, attempts = $3, last_error = $4, failed_transaction_id = $5, failed_id = $6, updated_at = now() WHERE name = $1),
          name, status, attempts, message, failed_position.transaction_id, failed_position.id
        )
      end

      def update_status(name : String, status : String) : Nil
        if status == RUNNING
          @db.exec(%(UPDATE "eventstore"."subscriptions" SET status = $2, attempts = 0, last_error = NULL, failed_transaction_id = NULL, failed_id = NULL, updated_at = now() WHERE name = $1), name, status)
        else
          @db.exec(%(UPDATE "eventstore"."subscriptions" SET status = $2, updated_at = now() WHERE name = $1), name, status)
        end
      end

      def try_lock(name : String) : Bool
        @lock_mutex.synchronize do
          lock_connection.query_one(%(SELECT pg_try_advisory_lock(hashtextextended($1, 0))), LOCK_PREFIX + name, as: Bool)
        rescue ex : DB::Error | IO::Error
          drop_lock_connection(ex)
          false
        end
      end

      def unlock(name : String) : Nil
        @lock_mutex.synchronize do
          connection = @lock_connection
          next if connection.nil?

          connection.query_one(%(SELECT pg_advisory_unlock(hashtextextended($1, 0))), LOCK_PREFIX + name, as: Bool)
        rescue ex : DB::Error | IO::Error
          # The session is gone, and its locks with it
          drop_lock_connection(ex)
        end
      end

      # Checks the session holding the locks. False once since the last call
      # it was found broken: its locks are gone, possibly held by others now.
      def locks_held? : Bool
        @lock_mutex.synchronize do
          if connection = @lock_connection
            begin
              connection.exec %(SELECT 1)
            rescue ex : DB::Error | IO::Error
              drop_lock_connection(ex)
            end
          end

          lost = @locks_lost
          @locks_lost = false
          !lost
        end
      end

      def heartbeat(instance_id : String, ttl : Time::Span) : Int32
        seconds = ttl.total_seconds
        @db.exec(
          %(INSERT INTO "eventstore"."subscription_instances" (instance_id, heartbeat_at) VALUES ($1, now()) ON CONFLICT (instance_id) DO UPDATE SET heartbeat_at = now()),
          instance_id
        )
        # Instances that died without leaving
        @db.exec(%(DELETE FROM "eventstore"."subscription_instances" WHERE heartbeat_at < now() - make_interval(secs => $1)), seconds * 10)
        @db.query_one(%(SELECT count(*)::int FROM "eventstore"."subscription_instances" WHERE heartbeat_at >= now() - make_interval(secs => $1)), seconds, as: Int32)
      end

      def leave(instance_id : String) : Nil
        @db.exec(%(DELETE FROM "eventstore"."subscription_instances" WHERE instance_id = $1), instance_id)
      end

      def wait_for_appends(timeout : Time::Span) : Nil
        if @stop_listening
          select
          when @wakeups.receive
          when timeout(timeout)
          end
        else
          sleep timeout
        end
      end

      def close : Nil
        @stop_listening.try(&.call)
        @stop_listening = nil
        @lock_mutex.synchronize do
          if connection = @lock_connection
            @lock_connection = nil
            begin
              connection.exec %(SELECT pg_advisory_unlock_all())
              connection.release
            rescue DB::Error | IO::Error
              # Closing the session released the locks
            end
          end
        end
      end

      private def states(sql : String, args : Array(DB::Any)) : Array(State)
        @db.query_all(sql, args: args, as: {String, Int64, Int64, String, Int32, String?, Int64?, Int64?, Time}).map do |row|
          name, transaction_id, id, status, attempts, last_error, failed_transaction_id, failed_id, updated_at = row
          failed = failed_transaction_id && failed_id ? ES::EventStore::LogPosition.new(failed_transaction_id, failed_id) : nil
          State.new(name, ES::EventStore::LogPosition.new(transaction_id, id), status, attempts, last_error, failed, updated_at)
        end
      end

      private def move(connection : DB::Database | DB::Connection, name : String, expected : ES::EventStore::LogPosition, position : ES::EventStore::LogPosition) : Bool
        result = connection.exec(
          %(UPDATE "eventstore"."subscriptions" SET position_transaction_id = $4, position_id = $5, updated_at = now() WHERE name = $1 AND position_transaction_id = $2 AND position_id = $3),
          name, expected.transaction_id, expected.id, position.transaction_id, position.id
        )
        result.rows_affected == 1
      end

      # The session the advisory locks live in, taken out of the pool for good
      private def lock_connection : DB::Connection
        @lock_connection ||= @db.checkout
      end

      private def drop_lock_connection(error : ::Exception) : Nil
        Log.warn { "Subscription locks lost with their database session: #{error.message}" }
        @lock_connection.try do |connection|
          connection.close
        rescue DB::Error | IO::Error
        end
        @lock_connection = nil
        @locks_lost = true
      end

      private def listen(url : String) : Nil
        {% if @top_level.has_constant?("PG") %}
          wakeups = @wakeups
          listener = PG.connect_listen(url, NOTIFY_CHANNEL, blocking: false) do |_|
            select
            when wakeups.send(nil)
            else
              # A wake-up is pending already
            end
          end
          @stop_listening = -> { listener.close; nil }
        {% else %}
          raise ES::Exception::InvalidState.new(%(listen_url needs crystal-pg: require "pg" before creating the subscription store))
        {% end %}
      end
    end
  end
end
