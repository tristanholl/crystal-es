require "../spec_helper"
require "pg"

# `ES::Subscriptions` on Postgres: projections with their positions in the
# projection database, reactors across instances with advisory locks. Needs a
# live database; runs only when ES_TEST_DATABASE_URL is set, e.g.
#   ES_TEST_DATABASE_URL=postgres://postgres@localhost:5432/es_test crystal spec

class SubPgPlaced < ES::Event
  include ::ES::EventDSL

  define_event "sub_pg_order", "subscriptions_pg_test.order_placed" do
    attribute :number, Int32
  end
end

class SubPgShipped < ES::Event
  include ::ES::EventDSL

  define_event "sub_pg_order", "subscriptions_pg_test.order_shipped" do
    attribute :number, Int32
  end
end

# Writes through `write`, so a batch and its position commit together
class SubPgOrdersAtomic < ES::Projection
  include ES::ProjectionDSL

  class_property fail_on : Int32? = nil
  class_property missing_key_on : Int32? = nil

  define_projection "subs_projections.orders_atomic", atomic: true do
    column :number, Int32, primary_key: true
    column :aggregate_id, UUID
  end

  apply(SubPgPlaced) do
    raise "cannot project order #{body.number}" if SubPgOrdersAtomic.fail_on == body.number
    write do |connection|
      connection.exec %(INSERT INTO "subs_projections"."orders_atomic" (number, aggregate_id) VALUES ($1, $2)), body.number, aggregate_id
    end
    # Like an aggregate hydrated here whose key was destroyed
    raise ES::Exception::NotFound.new("key destroyed") if SubPgOrdersAtomic.missing_key_on == body.number
  end
end

# A table name with upper case, which only exists quoted
class SubPgMixedCase < ES::Projection
  include ES::ProjectionDSL

  define_projection "subs_projections.MixedCase", atomic: true do
    column :number, Int32, primary_key: true
  end

  apply(SubPgPlaced) do
    write do |connection|
      connection.exec %(INSERT INTO "subs_projections"."MixedCase" (number) VALUES ($1)), body.number
    end
  end
end

# Writes on its own, one event at a time
class SubPgOrdersPlain < ES::Projection
  include ES::ProjectionDSL

  define_projection "subs_projections.orders_plain" do
    column :number, Int32, primary_key: true
  end

  apply(SubPgPlaced) do
    @projection_database.exec %(INSERT INTO "subs_projections"."orders_plain" (number) VALUES ($1)), body.number
  end
end

# Ships every order through the store it is given
class SubPgShipOrder < ES::Reactor
  class_property seen = [] of Int32

  def call(event : SubPgPlaced)
    number = event.body.as(SubPgPlaced::Body).number
    @event_store.append(SubPgShipped.new(actor_id: nil, command_handler: "test", number: number, aggregate_id: event.header.aggregate_id, aggregate_version: 2))
    SubPgShipOrder.seen << number
  end
end

module PostgresSubscriptionsSpec
  URL = ENV["ES_TEST_DATABASE_URL"]?

  @@db : DB::Database? = nil

  def self.db : DB::Database
    @@db ||= DB.open(URL || raise "ES_TEST_DATABASE_URL is not set")
  end

  def self.handlers : ES::EventHandlers
    handlers = ES::EventHandlers.new
    handlers.register(SubPgPlaced)
    handlers.register(SubPgShipped)
    handlers
  end

  # A fresh event store and projection schema, with the projections set up
  def self.fresh : ES::EventStoreAdapters::Postgres
    db.exec %(DROP SCHEMA IF EXISTS "eventstore" CASCADE)
    db.exec %(DROP SCHEMA IF EXISTS "subs_projections" CASCADE)
    db.exec %(CREATE SCHEMA "subs_projections")
    store = ES::EventStoreAdapters::Postgres.new(db, nil, nil)
    store.setup
    SubPgOrdersAtomic.new(event_handlers: handlers, event_store: store, projection_database: db).setup
    SubPgOrdersPlain.new(event_handlers: handlers, event_store: store, projection_database: db).setup
    SubPgMixedCase.new(event_handlers: handlers, event_store: store, projection_database: db).setup
    store
  end

  def self.bus(store : ES::EventStore, *subscribers) : ES::EventBus(ES::Reactor.class | ES::Projection.class)
    bus = ES::EventBus(ES::Reactor.class | ES::Projection.class).new(event_store: store, event_handlers: handlers)
    subscribers.each { |subscriber| bus.subscribe(SubPgPlaced, subscriber) }
    bus
  end

  def self.subscriptions(store : ES::EventStore, bus, listen = false) : ES::Subscriptions
    ES::Subscriptions.new(
      bus: bus, event_store: store, event_handlers: handlers, projection_database: db,
      listen_url: listen ? URL : nil,
      poll_interval: 20.milliseconds, rebalance_interval: 100.milliseconds,
      max_attempts: 2, retry_base_delay: 1.millisecond, retry_max_delay: 5.milliseconds,
    )
  end

  def self.placed(number : Int32) : SubPgPlaced
    SubPgPlaced.new(actor_id: nil, command_handler: "test", number: number)
  end

  def self.numbers(table : String) : Array(Int32)
    db.query_all(%(SELECT number FROM "subs_projections"."#{table}" ORDER BY number), as: Int32)
  end

  def self.eventually(timeout = 5.seconds, &block : -> Bool) : Nil
    deadline = Time.utc + timeout
    until block.call
      raise "condition not met within #{timeout}" if Time.utc > deadline
      sleep 10.milliseconds
    end
  end
end

describe "ES::Subscriptions on Postgres" do
  if PostgresSubscriptionsSpec::URL
    before_each do
      SubPgOrdersAtomic.fail_on = nil
      SubPgOrdersAtomic.missing_key_on = nil
      SubPgShipOrder.seen.clear
    end

    it "fills an empty atomic projection from the beginning and keeps its position next to its rows" do
      store = PostgresSubscriptionsSpec.fresh
      (1..3).each { |number| store.append(PostgresSubscriptionsSpec.placed(number)) }
      subs = PostgresSubscriptionsSpec.subscriptions(store, PostgresSubscriptionsSpec.bus(store, SubPgOrdersAtomic))

      subs.start
      (4..6).each { |number| store.append(PostgresSubscriptionsSpec.placed(number)) }

      PostgresSubscriptionsSpec.eventually { PostgresSubscriptionsSpec.numbers("orders_atomic") == (1..6).to_a }
      checkpoints = ES::ProjectionCheckpoints.new(PostgresSubscriptionsSpec.db, "subs_projections")
      checkpoints.fetch("projection:SubPgOrdersAtomic").should eq(store.log_head)
      PostgresSubscriptionsSpec.eventually { subs.status.first.caught_up? }
    ensure
      subs.try(&.stop)
    end

    it "rolls a failed batch back as a whole and applies it once fixed" do
      store = PostgresSubscriptionsSpec.fresh
      SubPgOrdersAtomic.fail_on = 3
      (1..5).each { |number| store.append(PostgresSubscriptionsSpec.placed(number)) }
      subs = PostgresSubscriptionsSpec.subscriptions(store, PostgresSubscriptionsSpec.bus(store, SubPgOrdersAtomic))

      subs.start
      PostgresSubscriptionsSpec.eventually { subs.status.first.status == "paused" }
      PostgresSubscriptionsSpec.numbers("orders_atomic").should be_empty
      subs.status.first.last_error.to_s.should contain("cannot project order 3")

      SubPgOrdersAtomic.fail_on = nil
      subs.resume(SubPgOrdersAtomic)
      PostgresSubscriptionsSpec.eventually { PostgresSubscriptionsSpec.numbers("orders_atomic") == (1..5).to_a }
    ensure
      subs.try(&.stop)
    end

    it "skips an event whose key is missing without keeping its half-applied writes" do
      store = PostgresSubscriptionsSpec.fresh
      SubPgOrdersAtomic.missing_key_on = 2
      (1..3).each { |number| store.append(PostgresSubscriptionsSpec.placed(number)) }
      subs = PostgresSubscriptionsSpec.subscriptions(store, PostgresSubscriptionsSpec.bus(store, SubPgOrdersAtomic))

      subs.start
      PostgresSubscriptionsSpec.eventually { subs.status.first.caught_up? }
      PostgresSubscriptionsSpec.numbers("orders_atomic").should eq([1, 3])
      subs.status.first.status.should eq("running")
    ensure
      subs.try(&.stop)
    end

    it "rebuilds a projection whose table name has upper case" do
      store = PostgresSubscriptionsSpec.fresh
      (1..2).each { |number| store.append(PostgresSubscriptionsSpec.placed(number)) }
      subs = PostgresSubscriptionsSpec.subscriptions(store, PostgresSubscriptionsSpec.bus(store, SubPgMixedCase))
      subs.start
      PostgresSubscriptionsSpec.eventually { PostgresSubscriptionsSpec.numbers("MixedCase") == [1, 2] }

      subs.rebuild(SubPgMixedCase)
      PostgresSubscriptionsSpec.eventually { PostgresSubscriptionsSpec.numbers("MixedCase") == [1, 2] }
    ensure
      subs.try(&.stop)
    end

    it "rebuilds a projection from the beginning" do
      store = PostgresSubscriptionsSpec.fresh
      (1..4).each { |number| store.append(PostgresSubscriptionsSpec.placed(number)) }
      subs = PostgresSubscriptionsSpec.subscriptions(store, PostgresSubscriptionsSpec.bus(store, SubPgOrdersAtomic))
      subs.start
      PostgresSubscriptionsSpec.eventually { PostgresSubscriptionsSpec.numbers("orders_atomic").size == 4 }

      PostgresSubscriptionsSpec.db.exec %(DELETE FROM "subs_projections"."orders_atomic" WHERE number = 2)
      subs.rebuild(SubPgOrdersAtomic)

      PostgresSubscriptionsSpec.eventually { PostgresSubscriptionsSpec.numbers("orders_atomic") == (1..4).to_a }
    ensure
      subs.try(&.stop)
    end

    it "applies a plain projection one event at a time, and rebuilds it only when paused" do
      store = PostgresSubscriptionsSpec.fresh
      subs = PostgresSubscriptionsSpec.subscriptions(store, PostgresSubscriptionsSpec.bus(store, SubPgOrdersPlain))
      subs.start
      (1..3).each { |number| store.append(PostgresSubscriptionsSpec.placed(number)) }
      PostgresSubscriptionsSpec.eventually { PostgresSubscriptionsSpec.numbers("orders_plain") == [1, 2, 3] }

      expect_raises(ES::Exception::InvalidState, /pause it/) { subs.rebuild(SubPgOrdersPlain) }

      subs.pause(SubPgOrdersPlain)
      sleep 150.milliseconds
      subs.rebuild(SubPgOrdersPlain)
      PostgresSubscriptionsSpec.eventually { PostgresSubscriptionsSpec.numbers("orders_plain") == [1, 2, 3] }
    ensure
      subs.try(&.stop)
    end

    it "refuses a projection whose table has rows but no position, unless it starts now" do
      store = PostgresSubscriptionsSpec.fresh
      store.append(PostgresSubscriptionsSpec.placed(1))
      PostgresSubscriptionsSpec.db.exec %(INSERT INTO "subs_projections"."orders_atomic" (number, aggregate_id) VALUES (1, $1)), UUID.v7
      bus = PostgresSubscriptionsSpec.bus(store, SubPgOrdersAtomic)

      expect_raises(ES::Exception::InvalidState, /has rows in 'subs_projections.orders_atomic' but no subscription position/) do
        PostgresSubscriptionsSpec.subscriptions(store, bus).start
      end

      subs = PostgresSubscriptionsSpec.subscriptions(store, bus).configure(SubPgOrdersAtomic, start: :now)
      subs.start
      store.append(PostgresSubscriptionsSpec.placed(2))
      PostgresSubscriptionsSpec.eventually { PostgresSubscriptionsSpec.numbers("orders_atomic") == [1, 2] }
    ensure
      subs.try(&.stop)
    end

    it "runs a reactor exactly once across instances, its appends committing with its position" do
      store = PostgresSubscriptionsSpec.fresh
      first = PostgresSubscriptionsSpec.subscriptions(store, PostgresSubscriptionsSpec.bus(store, SubPgShipOrder, SubPgOrdersAtomic), listen: true)
      second = PostgresSubscriptionsSpec.subscriptions(store, PostgresSubscriptionsSpec.bus(store, SubPgShipOrder, SubPgOrdersAtomic), listen: true)
      first.start
      second.start
      PostgresSubscriptionsSpec.eventually { first.status.count(&.owned?) == 1 && second.status.count(&.owned?) == 1 }

      (1..30).each { |number| store.append(PostgresSubscriptionsSpec.placed(number)) }

      PostgresSubscriptionsSpec.eventually { SubPgShipOrder.seen.size >= 30 && PostgresSubscriptionsSpec.numbers("orders_atomic").size == 30 }
      sleep 200.milliseconds
      SubPgShipOrder.seen.sort.should eq((1..30).to_a)
      shipped = store.read_log(ES::EventStore::LogPosition::ZERO, handles: [SubPgShipped.handle]).events
      shipped.map(&.body["number"].as_i).sort!.should eq((1..30).to_a)
    ensure
      first.try(&.stop)
      second.try(&.stop)
    end
  else
    pending "runs the subscription scenarios against Postgres (set ES_TEST_DATABASE_URL)", tags: "db" do
    end
  end
end
