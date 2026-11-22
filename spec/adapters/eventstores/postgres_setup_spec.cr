require "../../spec_helper"
require "pg"

# `setup` on an existing store builds missing indexes CONCURRENTLY, so appends
# keep running during the build, and rebuilds the ones a failed build left
# invalid. Needs a live database; runs when ES_TEST_DATABASE_URL is set.
module PostgresSetupSpec
  URL = ENV["ES_TEST_DATABASE_URL"]?

  @@db : DB::Database? = nil

  def self.db : DB::Database
    @@db ||= begin
      url = URL || raise "ES_TEST_DATABASE_URL is not set"
      # Open the connections up front, so the blocker, the build and the
      # append below don't wait on connection setup
      DB.open(url + (url.includes?('?') ? "&" : "?") + "initial_pool_size=8&max_idle_pool_size=8")
    end
  end

  def self.fresh_store : ES::EventStoreAdapters::Postgres
    db.exec %(DROP SCHEMA IF EXISTS "eventstore" CASCADE)
    store = ES::EventStoreAdapters::Postgres.new(db, nil, nil)
    store.setup
    store
  end

  def self.index_oid(name : String) : Int64?
    db.query_one?(%(SELECT c.oid::int8 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'eventstore' AND c.relname = $1), name, as: Int64)
  end

  def self.index_valid?(name : String) : Bool
    db.query_one(%(SELECT i.indisvalid FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'eventstore' AND c.relname = $1), name, as: Bool)
  end

  # Keeps a write transaction on the events table open while the block runs.
  # A concurrent index build waits for it before scanning the table. It is
  # rolled back even when the block fails, or the specs after it would hang.
  def self.with_writer(&)
    writer = db.checkout
    begin
      writer.exec "BEGIN"
      writer.exec %(INSERT INTO "eventstore"."events" (header, body) VALUES ($1::jsonb, '{}'::jsonb)), %({"event_id":"#{UUID.v7}"})
      yield
    ensure
      writer.exec "ROLLBACK"
      writer.release
    end
  end

  def self.wait_for_index_build
    50.times do
      return if db.query_one(%(SELECT EXISTS (SELECT FROM pg_stat_progress_create_index WHERE datname = current_database())), as: Bool)
      sleep 20.milliseconds
    end
    raise "no index build started"
  end

  def self.within(span : Time::Span, what : String, &block : -> T) : T forall T
    done = Channel(T | Exception).new(1)
    spawn do
      done.send(block.call)
    rescue ex
      done.send(ex)
    end
    result = select
    when value = done.receive then value
    when timeout(span) then raise "#{what} did not finish within #{span}"
    end
    raise result if result.is_a?(Exception)
    result
  end
end

describe "ES::EventStoreAdapters::Postgres#setup on an existing store" do
  if PostgresSetupSpec::URL
    it "builds missing indexes without blocking appends" do
      store = PostgresSetupSpec.fresh_store
      store.append(DummyEvent.new)
      PostgresSetupSpec.db.exec %(DROP INDEX "eventstore"."events_tags_idx")

      # The build waits for the open writer, so it is still running when the
      # append below comes in. A plain CREATE INDEX would hold the append back.
      setup = Channel(Bool | Exception).new(1)
      PostgresSetupSpec.with_writer do
        spawn do
          setup.send(store.setup.as(Bool))
        rescue ex
          setup.send(ex)
        end
        PostgresSetupSpec.wait_for_index_build

        PostgresSetupSpec.within(2.seconds, "an append during the index build") { store.append(DummyEvent.new) }
      end
      select
      when result = setup.receive then raise result if result.is_a?(Exception)
      when timeout(10.seconds) then raise "setup did not finish"
      end
      PostgresSetupSpec.index_valid?("events_tags_idx").should be_true
    end

    it "builds each missing index once when setups run at the same time" do
      store = PostgresSetupSpec.fresh_store
      store.append(DummyEvent.new)
      PostgresSetupSpec.db.exec %(DROP INDEX "eventstore"."events_tags_idx")
      PostgresSetupSpec.db.exec %(DROP INDEX "eventstore"."events_event_handle_idx")

      # Holding the build up makes the setups overlap. Without the lock, the
      # second build deadlocks with the first and one setup raises.
      results = Channel(Exception?).new(3)
      PostgresSetupSpec.with_writer do
        3.times do
          spawn do
            ES::EventStoreAdapters::Postgres.new(PostgresSetupSpec.db, nil, nil).setup
            results.send(nil)
          rescue ex
            results.send(ex)
          end
        end
        PostgresSetupSpec.wait_for_index_build
        sleep 300.milliseconds
      end

      3.times do
        select
        when result = results.receive then raise result if result
        when timeout(20.seconds) then raise "a setup did not finish"
        end
      end
      PostgresSetupSpec.index_valid?("events_tags_idx").should be_true
      PostgresSetupSpec.index_valid?("events_event_handle_idx").should be_true
    end

    it "rebuilds an index a failed build left invalid" do
      store = PostgresSetupSpec.fresh_store
      store.append(DummyEvent.new)
      db = PostgresSetupSpec.db
      db.exec %(DROP INDEX "eventstore"."events_event_id_idx")
      db.exec %(INSERT INTO "eventstore"."events" (header, body) SELECT header || '{"aggregate_id":"duplicate"}'::jsonb, body FROM "eventstore"."events")

      expect_raises(PQ::PQError, /duplicate|could not create unique index/) { store.setup }
      PostgresSetupSpec.index_valid?("events_event_id_idx").should be_false

      db.exec %(DELETE FROM "eventstore"."events" WHERE header->>'aggregate_id' = 'duplicate')
      store.setup

      PostgresSetupSpec.index_valid?("events_event_id_idx").should be_true
      PostgresSetupSpec.index_oid("events_event_id_idx_rebuild").should be_nil
    end

    it "needs no more than one connection" do
      PostgresSetupSpec.fresh_store.append(DummyEvent.new)
      PostgresSetupSpec.db.exec %(DROP INDEX "eventstore"."events_tags_idx")
      url = PostgresSetupSpec::URL || raise "ES_TEST_DATABASE_URL is not set"
      single = DB.open(url + (url.includes?('?') ? "&" : "?") + "max_pool_size=1&checkout_timeout=2")

      begin
        ES::EventStoreAdapters::Postgres.new(single, nil, nil).setup
      ensure
        single.close
      end
      PostgresSetupSpec.index_valid?("events_tags_idx").should be_true
    end

    it "leaves an index alone while a build of it is still running" do
      store = PostgresSetupSpec.fresh_store
      db = PostgresSetupSpec.db
      db.exec %(DROP INDEX "eventstore"."events_event_handle_idx")

      # Another session builds the index, as an operator or a second instance
      # booting at the same time would. While it waits, the index is invalid.
      build = Channel(Exception?).new(1)
      oid = nil
      PostgresSetupSpec.with_writer do
        spawn do
          db.exec ES::EventStoreAdapters::Postgres::EVENT_HANDLE_INDEX.sub(" INDEX ", " INDEX CONCURRENTLY ")
          build.send(nil)
        rescue ex
          build.send(ex)
        end
        PostgresSetupSpec.wait_for_index_build
        PostgresSetupSpec.index_valid?("events_event_handle_idx").should be_false
        oid = PostgresSetupSpec.index_oid("events_event_handle_idx")

        # Dropping the index would wait for the build, and building it again
        # would deadlock with it
        PostgresSetupSpec.within(2.seconds, "setup during another session's build") { store.setup }
      end

      select
      when result = build.receive then raise result if result
      when timeout(10.seconds) then raise "the build did not finish"
      end
      PostgresSetupSpec.index_valid?("events_event_handle_idx").should be_true
      PostgresSetupSpec.index_oid("events_event_handle_idx").should eq(oid)
    end
  else
    pending "builds indexes concurrently on existing stores (set ES_TEST_DATABASE_URL)", tags: "db" do
    end
  end
end
