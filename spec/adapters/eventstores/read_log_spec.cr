require "../../spec_helper"
require "pg"

# `EventStore#read_log`, `#log_head` and `#transaction`. The same scenarios run
# against every adapter; the Postgres ones need a live database and only run
# when ES_TEST_DATABASE_URL is set, e.g.
#   ES_TEST_DATABASE_URL=postgres://postgres@localhost:5432/es_test crystal spec

class LogItemAdded < ES::Event
  include ::ES::EventDSL

  define_event "log_cart", "log_test.item_added" do
    attribute :sku, String
  end
end

class LogItemRemoved < ES::Event
  include ::ES::EventDSL

  define_event "log_cart", "log_test.item_removed" do
    attribute :sku, String
  end
end

class LogSeatBooked < ES::Event
  include ::ES::EventDSL

  define_event "log_show", "log_test.seat_booked" do
    attribute :show_id, UUID
    tag :show_id, UUID
  end
end

private def added(sku = "sku", aggregate_id = UUID.v7, version = 1)
  LogItemAdded.new(actor_id: nil, command_handler: "test", sku: sku, aggregate_id: aggregate_id, aggregate_version: version)
end

private def removed(sku = "sku", aggregate_id = UUID.v7, version = 1)
  LogItemRemoved.new(actor_id: nil, command_handler: "test", sku: sku, aggregate_id: aggregate_id, aggregate_version: version)
end

private def booked(show_id : UUID)
  LogSeatBooked.new(actor_id: nil, command_handler: "test", show_id: show_id, tags: {show_id: show_id})
end

private def skus(events : Array(ES::EventStore::Event)) : Array(String)
  events.map(&.body.["sku"].as_s)
end

# Log scenarios shared by every adapter. `build` returns an empty store.
private def log_scenarios(&build : -> ES::EventStore)
  it "starts empty" do
    store = build.call

    store.log_head.should eq(ES::EventStore::LogPosition::ZERO)
    page = store.read_log(ES::EventStore::LogPosition::ZERO)
    page.events.should be_empty
    page.last_position.should eq(ES::EventStore::LogPosition::ZERO)
  end

  it "reads every event in append order, each with a growing log position, up to the head" do
    store = build.call
    %w[a b c].each { |sku| store.append(added(sku)) }

    page = store.read_log(ES::EventStore::LogPosition::ZERO)

    skus(page.events).should eq(%w[a b c])
    positions = page.events.compact_map(&.log_position)
    positions.should eq(positions.sort)
    positions.uniq.size.should eq(3)
    page.last_position.should eq(store.log_head)
    page.last_position.should eq(positions.last)
  end

  it "resumes after a position and pages by limit" do
    store = build.call
    %w[a b c d e].each { |sku| store.append(added(sku)) }

    first = store.read_log(ES::EventStore::LogPosition::ZERO, limit: 2)
    skus(first.events).should eq(%w[a b])
    first.last_position.should eq(first.events.last.log_position)

    second = store.read_log(first.last_position, limit: 2)
    skus(second.events).should eq(%w[c d])

    third = store.read_log(second.last_position, limit: 2)
    skus(third.events).should eq(%w[e])
    third.last_position.should eq(store.log_head)

    store.read_log(third.last_position).events.should be_empty
  end

  it "filters by event type and still moves past the events it leaves out" do
    store = build.call
    store.append(added("a"))
    store.append(removed("b"))
    store.append(added("c"))
    store.append(removed("d"))

    page = store.read_log(ES::EventStore::LogPosition::ZERO, handles: [LogItemRemoved.handle])

    skus(page.events).should eq(%w[b d])
    page.last_position.should eq(store.log_head)
    store.read_log(ES::EventStore::LogPosition::ZERO, handles: [] of String).events.should be_empty
  end

  it "splits events into disjoint partitions by aggregate, keeping an aggregate in one" do
    store = build.call
    aggregates = Array.new(6) { UUID.v7 }
    aggregates.each { |id| store.append(added("#{id}-1", id, 1)) }
    aggregates.each { |id| store.append(added("#{id}-2", id, 2)) }

    parts = Array.new(3) { |index| store.read_log(ES::EventStore::LogPosition::ZERO, partition: {index, 3}).events }

    parts.sum(&.size).should eq(12)
    parts.flat_map { |events| skus(events) }.sort!.should eq(skus(store.read_log(ES::EventStore::LogPosition::ZERO).events).sort)
    aggregates.each do |id|
      holding = parts.select { |events| events.any? { |event| event.header["aggregate_id"].as_s == id.to_s } }
      holding.size.should eq(1)
      skus(holding.first.select { |event| event.header["aggregate_id"].as_s == id.to_s }).should eq(["#{id}-1", "#{id}-2"])
    end
  end

  it "refuses invalid options" do
    store = build.call

    expect_raises(ES::Exception::InvalidState, /limit/) { store.read_log(ES::EventStore::LogPosition::ZERO, limit: 0) }
    expect_raises(ES::Exception::InvalidState, /partition count/) { store.read_log(ES::EventStore::LogPosition::ZERO, partition: {0, 0}) }
    expect_raises(ES::Exception::InvalidState, /partition index/) { store.read_log(ES::EventStore::LogPosition::ZERO, partition: {2, 2}) }
  end

  it "commits every append of a transaction together and returns the block's value" do
    store = build.call

    value = store.transaction do |bound|
      bound.append(added("a"))
      bound.append([added("b"), added("c")])
      :done
    end

    value.should eq(:done)
    skus(store.read_log(ES::EventStore::LogPosition::ZERO).events).should eq(%w[a b c])
  end

  it "appends nothing when the block raises" do
    store = build.call
    show = UUID.v7
    store.append(added("before"))

    expect_raises(Exception, "boom") do
      store.transaction do |bound|
        bound.append(added("lost"))
        bound.append(booked(show))
        raise "boom"
      end
    end

    skus(store.read_log(ES::EventStore::LogPosition::ZERO).events).should eq(%w[before])
    # The tag version raised inside rolled back with it
    store.read_for_decision(ES::Query.new(ES::QueryItem.new(tags: {show_id: show}))).versions.values.should eq([0_i64])
    store.append([booked(show)], store.read_for_decision(ES::Query.new(ES::QueryItem.new(tags: {show_id: show}))).condition)
  end

  it "reads its own appends inside the transaction, and nested transactions join it" do
    store = build.call
    aggregate = UUID.v7

    store.transaction do |bound|
      bound.append(added("a", aggregate, 1))
      bound.fetch_events(aggregate).size.should eq(1)
      bound.transaction do |nested|
        nested.should be(bound)
        nested.append(added("b", aggregate, 2))
      end
      bound.fetch_events(aggregate).size.should eq(2)
    end

    store.fetch_events(aggregate).size.should eq(2)
  end

  it "keeps the transaction usable after a failed conditional append" do
    store = build.call
    show = UUID.v7
    stale = store.read_for_decision(ES::Query.new(ES::QueryItem.new(tags: {show_id: show}))).condition
    store.append(booked(show))

    store.transaction do |bound|
      expect_raises(ES::Exception::Conflict) { bound.append([booked(show)], stale) }
      bound.append(added("after the conflict"))
    end

    skus(store.read_log(ES::EventStore::LogPosition::ZERO, handles: [LogItemAdded.handle]).events).should eq(["after the conflict"])
  end
end

describe ES::EventStoreAdapters::InMemory do
  describe "#read_log" do
    log_scenarios { ES::EventStoreAdapters::InMemory.new }

    it "holds the head back while a transaction is open" do
      store = ES::EventStoreAdapters::InMemory.new
      store.append(added("committed"))
      head = store.log_head

      store.transaction do |bound|
        bound.append(added("open"))
        store.log_head.should eq(head)
        skus(store.read_log(ES::EventStore::LogPosition::ZERO).events).should eq(%w[committed])
      end

      skus(store.read_log(ES::EventStore::LogPosition::ZERO).events).should eq(%w[committed open])
    end

    it "refuses an append that bypasses the transaction's store instead of waiting on itself" do
      store = ES::EventStoreAdapters::InMemory.new

      expect_raises(Exception, /recursively|deadlock/i) do
        store.transaction { |_bound| store.append(added("bypass")) }
      end
      store.read_log(ES::EventStore::LogPosition::ZERO).events.should be_empty
    end
  end
end

module PostgresReadLogSpec
  URL = ENV["ES_TEST_DATABASE_URL"]?

  @@db : DB::Database? = nil

  def self.db : DB::Database
    @@db ||= DB.open(URL || raise "ES_TEST_DATABASE_URL is not set")
  end

  def self.fresh_store : ES::EventStoreAdapters::Postgres
    db.exec %(DROP SCHEMA IF EXISTS "eventstore" CASCADE)
    store = ES::EventStoreAdapters::Postgres.new(db, nil, nil)
    store.setup
    store
  end
end

describe ES::EventStoreAdapters::Postgres do
  describe "#read_log" do
    if PostgresReadLogSpec::URL
      log_scenarios { PostgresReadLogSpec.fresh_store }

      # Positions are taken at insert, not at commit: a transaction that
      # inserts first can commit last. A reader resuming after the last
      # position it saw would then skip the late event for good. The head
      # holds every reader back until such a transaction has finished.
      it "never skips an event that commits after a later one" do
        store = PostgresReadLogSpec.fresh_store
        inserted = Channel(Nil).new
        release = Channel(Nil).new
        done = Channel(Nil).new

        spawn do
          store.transaction do |bound|
            bound.append(added("slow"))
            inserted.send(nil)
            release.receive
          end
          done.send(nil)
        end

        inserted.receive
        store.append(added("fast"))

        # The fast event is committed, but readable only once the slow one is
        page = store.read_log(ES::EventStore::LogPosition::ZERO)
        page.events.should be_empty
        page.last_position.should eq(ES::EventStore::LogPosition::ZERO)

        release.send(nil)
        done.receive

        events = store.read_log(page.last_position).events
        skus(events).should eq(%w[slow fast])
      end

      it "adds the transaction column to a store set up without it, reading older events first" do
        db = PostgresReadLogSpec.db
        store = PostgresReadLogSpec.fresh_store
        db.exec %(DROP INDEX "eventstore"."events_log_position_idx")
        db.exec %(ALTER TABLE "eventstore"."events" DROP COLUMN "transaction_id")
        store.append(added("old"))

        store = ES::EventStoreAdapters::Postgres.new(db, nil, nil)
        store.setup
        store.append(added("new"))

        db.query_one(%(SELECT EXISTS (SELECT FROM pg_indexes WHERE schemaname = 'eventstore' AND indexname = 'events_log_position_idx')), as: Bool).should be_true
        page = store.read_log(ES::EventStore::LogPosition::ZERO)
        skus(page.events).should eq(%w[old new])
        page.events.first.log_position.try(&.transaction_id).should eq(0)
      end

      it "refuses transaction ids ahead of the cluster's counter, as after a restore elsewhere" do
        store = PostgresReadLogSpec.fresh_store
        store.append(added("restored"))
        PostgresReadLogSpec.db.exec %(ALTER TABLE "eventstore"."events" DISABLE TRIGGER USER)
        PostgresReadLogSpec.db.exec %(INSERT INTO "eventstore"."events" (header, body, transaction_id) SELECT jsonb_set(header, '{event_id}', to_jsonb(gen_random_uuid()::text)) || jsonb_build_object('aggregate_id', gen_random_uuid()::text), body, '999999999999'::xid8 FROM "eventstore"."events" LIMIT 1)

        restored = ES::EventStoreAdapters::Postgres.new(PostgresReadLogSpec.db, nil, nil)
        expect_raises(ES::Exception::InvalidState, /ahead of this cluster's transaction counter/) { restored.log_head }
      end

      it "uses the log position index to read after a position" do
        store = PostgresReadLogSpec.fresh_store
        store.append(added("a"))
        plan = PostgresReadLogSpec.db.using_connection do |connection|
          connection.exec "SET enable_seqscan = off"
          rows = connection.query_all(%(EXPLAIN SELECT id FROM "eventstore"."events" WHERE (COALESCE(transaction_id, '0'::xid8), id) > ('0'::xid8, 0) ORDER BY COALESCE(transaction_id, '0'::xid8), id LIMIT 10), as: String)
          connection.exec "RESET enable_seqscan"
          rows.join("\n")
        end
        plan.should contain("events_log_position_idx")
      end
    else
      pending "runs the log scenarios against Postgres (set ES_TEST_DATABASE_URL)", tags: "db" do
      end
    end
  end
end
