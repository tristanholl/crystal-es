require "../../spec_helper"
require "pg"

# Both subscription stores run the same scenarios; the Postgres ones need a
# live database and only run when ES_TEST_DATABASE_URL is set.

class StoreSpecEvent < ES::Event
  include ::ES::EventDSL

  define_event "store_spec", "subscription_store_test.happened" do
    attribute :number, Int32
  end
end

private def happened(number = 1)
  StoreSpecEvent.new(actor_id: nil, command_handler: "test", number: number)
end

private def at(id : Int64) : ES::EventStore::LogPosition
  ES::EventStore::LogPosition.new(0_i64, id)
end

# `build` returns an event store and its subscription store, both empty
private def store_scenarios(&build : -> {ES::EventStore, ES::SubscriptionStore})
  it "creates a subscription once and lists it" do
    _, store = build.call

    store.fetch("reactor:A").should be_nil
    store.create("reactor:A", at(3))
    store.create("reactor:A", at(9))

    state = store.fetch("reactor:A") || raise "missing"
    state.position.should eq(at(3))
    state.status.should eq("running")
    state.attempts.should eq(0)
    store.all.map(&.name).should eq(["reactor:A"])
  end

  it "moves a position only from the expected one" do
    _, store = build.call
    store.create("reactor:A", at(1))

    store.advance("reactor:A", at(1), at(5)).should be_true
    store.advance("reactor:A", at(1), at(7)).should be_false
    store.fetch("reactor:A").try(&.position).should eq(at(5))
  end

  it "moves a position with a transaction, and not when it rolls back" do
    events, store = build.call
    store.create("reactor:A", at(0))

    events.transaction do |bound|
      bound.append(happened(1))
      store.advance("reactor:A", at(0), at(1), within: bound)
    end
    store.fetch("reactor:A").try(&.position).should eq(at(1))

    expect_raises(Exception, "boom") do
      events.transaction do |bound|
        bound.append(happened(2))
        store.advance("reactor:A", at(1), at(2), within: bound)
        raise "boom"
      end
    end
    store.fetch("reactor:A").try(&.position).should eq(at(1))
    events.read_log(ES::EventStore::LogPosition::ZERO).events.size.should eq(1)
  end

  it "refuses a stale move inside a transaction, rolling the transaction back" do
    events, store = build.call
    store.create("reactor:A", at(4))

    expect_raises(ES::Exception::StaleCheckpoint) do
      events.transaction do |bound|
        bound.append(happened)
        store.advance("reactor:A", at(3), at(5), within: bound)
      end
    end
    store.fetch("reactor:A").try(&.position).should eq(at(4))
    events.read_log(ES::EventStore::LogPosition::ZERO).events.should be_empty
  end

  it "records failures, and clears them when running again or reset" do
    _, store = build.call
    store.create("reactor:A", at(2))

    store.record_failure("reactor:A", 2, "RuntimeError: boom", at(3), "failing")
    state = store.fetch("reactor:A") || raise "missing"
    {state.status, state.attempts, state.last_error, state.failed_position}.should eq({"failing", 2, "RuntimeError: boom", at(3)})

    store.update_status("reactor:A", "paused")
    store.fetch("reactor:A").try(&.paused?).should be_true
    store.fetch("reactor:A").try(&.attempts).should eq(2)

    store.update_status("reactor:A", "running")
    state = store.fetch("reactor:A") || raise "missing"
    {state.status, state.attempts, state.last_error, state.failed_position}.should eq({"running", 0, nil, nil})

    store.record_failure("reactor:A", 1, "boom", at(3), "failing")
    store.reset("reactor:A", at(3))
    state = store.fetch("reactor:A") || raise "missing"
    {state.position, state.status, state.attempts}.should eq({at(3), "running", 0})
  end

  it "records a position unconditionally" do
    _, store = build.call

    store.record_position("projection:P", at(8))
    store.record_position("projection:P", at(2))
    store.fetch("projection:P").try(&.position).should eq(at(2))
  end

  it "counts the instances alive and forgets one that leaves" do
    _, store = build.call

    store.heartbeat("one", 1.minute).should eq(1)
    store.heartbeat("two", 1.minute).should eq(2)
    store.leave("one")
    store.heartbeat("two", 1.minute).should eq(1)
  end
end

describe ES::SubscriptionStoreAdapters::InMemory do
  store_scenarios do
    events = ES::EventStoreAdapters::InMemory.new
    {events.as(ES::EventStore), events.subscription_store}
  end

  it "is one store per event store, shared like a database" do
    events = ES::EventStoreAdapters::InMemory.new
    events.subscription_store.should be(events.subscription_store)
  end
end

module PostgresSubscriptionStoreSpec
  URL = ENV["ES_TEST_DATABASE_URL"]?

  @@db : DB::Database? = nil

  def self.db : DB::Database
    @@db ||= DB.open(URL || raise "ES_TEST_DATABASE_URL is not set")
  end

  def self.fresh : {ES::EventStoreAdapters::Postgres, ES::SubscriptionStoreAdapters::Postgres}
    db.exec %(DROP SCHEMA IF EXISTS "eventstore" CASCADE)
    events = ES::EventStoreAdapters::Postgres.new(db, nil, nil)
    events.setup
    store = ES::SubscriptionStoreAdapters::Postgres.new(db)
    store.setup
    {events, store}
  end
end

describe ES::SubscriptionStoreAdapters::Postgres do
  if PostgresSubscriptionStoreSpec::URL
    store_scenarios do
      events, store = PostgresSubscriptionStoreSpec.fresh
      {events.as(ES::EventStore), store.as(ES::SubscriptionStore)}
    end

    it "installs the notification trigger only for a store that listens" do
      _, store = PostgresSubscriptionStoreSpec.fresh
      trigger = -> { PostgresSubscriptionStoreSpec.db.query_one(%(SELECT EXISTS (SELECT FROM pg_trigger WHERE tgname = 'notify_subscriptions')), as: Bool) }
      trigger.call.should be_false

      listening = ES::SubscriptionStoreAdapters::Postgres.new(PostgresSubscriptionStoreSpec.db, listen_url: PostgresSubscriptionStoreSpec::URL)
      listening.setup
      trigger.call.should be_true
      listening.close
      store.close
    end

    it "sets up idempotently" do
      _, store = PostgresSubscriptionStoreSpec.fresh
      store.setup
      store.setup
    end

    it "lets one session at a time hold a subscription's lock" do
      _, first = PostgresSubscriptionStoreSpec.fresh
      second = ES::SubscriptionStoreAdapters::Postgres.new(PostgresSubscriptionStoreSpec.db)

      first.try_lock("reactor:A").should be_true
      second.try_lock("reactor:A").should be_false
      first.unlock("reactor:A")
      second.try_lock("reactor:A").should be_true

      second.close
      first.try_lock("reactor:A").should be_true
      first.close
    end

    it "reports locks lost with their session, and locks again on a new one" do
      _, store = PostgresSubscriptionStoreSpec.fresh
      other = ES::SubscriptionStoreAdapters::Postgres.new(PostgresSubscriptionStoreSpec.db)
      store.try_lock("reactor:A").should be_true
      store.locks_held?.should be_true

      PostgresSubscriptionStoreSpec.db.exec %(SELECT pg_terminate_backend(pid) FROM pg_locks WHERE locktype = 'advisory' AND granted AND pid <> pg_backend_pid())

      store.locks_held?.should be_false
      store.locks_held?.should be_true
      other.try_lock("reactor:A").should be_true
      store.try_lock("reactor:A").should be_false
      other.close
      store.close
    end

    it "wakes a waiting subscriber on append when listening" do
      events, _ = PostgresSubscriptionStoreSpec.fresh
      store = ES::SubscriptionStoreAdapters::Postgres.new(PostgresSubscriptionStoreSpec.db, listen_url: PostgresSubscriptionStoreSpec::URL)
      store.setup
      sleep 100.milliseconds

      spawn do
        sleep 50.milliseconds
        events.append(happened)
      end
      started = Time.utc
      store.wait_for_appends(5.seconds)
      (Time.utc - started).should be < 2.seconds
      store.close
    end
  else
    pending "runs the subscription store scenarios against Postgres (set ES_TEST_DATABASE_URL)", tags: "db" do
    end
  end
end
