require "../spec_helper"

# `ES::Subscriptions` on the in-memory event store, whose subscription store
# is shared by every `ES::Subscriptions` on it, the way instances share a
# database. The Postgres scenarios live in subscriptions_postgres_spec.cr.

class SubOrderPlaced < ES::Event
  include ::ES::EventDSL

  define_event "sub_order", "subscriptions_test.order_placed" do
    attribute :number, Int32
  end
end

class SubOrderShipped < ES::Event
  include ::ES::EventDSL

  define_event "sub_order", "subscriptions_test.order_shipped" do
    attribute :number, Int32
  end
end

private def placed(number : Int32, aggregate_id = UUID.v7, version = 1)
  SubOrderPlaced.new(actor_id: nil, command_handler: "test", number: number, aggregate_id: aggregate_id, aggregate_version: version)
end

private def number_of(event : ES::Event) : Int32
  event.body.as(SubOrderPlaced::Body).number
end

# Records what it saw and ships every order, appending through the store it
# was given, so the shipment commits with the reactor's position
class SubShipOrder < ES::Reactor
  class_property seen = [] of Int32
  class_property failing : Int32? = nil

  def call(event : SubOrderPlaced)
    number = number_of(event)
    @event_store.append(SubOrderShipped.new(actor_id: nil, command_handler: "test", number: number, aggregate_id: event.header.aggregate_id, aggregate_version: event.header.aggregate_version + 1000))
    raise "cannot ship order #{number}\nDETAIL: row (secret-value)" if SubShipOrder.failing == number || SubShipOrder.failing == -1
    SubShipOrder.seen << number
  end
end

# Several plain reactors, for sharing out between instances. They yield
# while handling an event, as real handlers waiting on a database do, so two
# instances processing the same subscription would interleave and both
# record the event.
{% for index in 1..4 %}
  class SubCounter{{ index }} < ES::Reactor
    class_property seen = [] of Int32

    def call(event : SubOrderPlaced)
      sleep 1.millisecond
      SubCounter{{ index }}.seen << number_of(event)
    end
  end
{% end %}

# Records the shipments it saw, one step further down a chain of reactors
class SubShipmentLog < ES::Reactor
  class_property seen = [] of Int32

  def call(event : SubOrderShipped)
    SubShipmentLog.seen << event.body.as(SubOrderShipped::Body).number
  end
end

# Reacts to every shipment with another one, without end
class SubEndlessShipping < ES::Reactor
  def call(event : SubOrderShipped)
    @event_store.append(SubOrderShipped.new(actor_id: nil, command_handler: "test", number: 0, aggregate_id: UUID.v7, aggregate_version: 1))
  end
end

# Records the version order it saw per aggregate
class SubOrderLog < ES::Reactor
  class_property seen = {} of String => Array(Int32)

  def call(event : SubOrderPlaced)
    (SubOrderLog.seen[event.header.aggregate_id.to_s] ||= [] of Int32) << event.header.aggregate_version
  end
end

class SubEventStoreProjection < ES::Projection
  include ES::ProjectionDSL

  define_projection "eventstore.sneaky" do
    column :id, UUID, primary_key: true
  end

  apply(SubOrderPlaced) do
  end
end

class SubInitProjection < ES::Projection
  include ES::ProjectionDSL

  define_projection "subs.init_projection", init: true do
    column :id, UUID, primary_key: true
  end

  apply(SubOrderPlaced) do
  end
end

private def sub_handlers : ES::EventHandlers
  handlers = ES::EventHandlers.new
  handlers.register(SubOrderPlaced)
  handlers.register(SubOrderShipped)
  handlers
end

private def sub_bus(store : ES::EventStore, handlers : ES::EventHandlers, *reactors) : ES::EventBus(ES::Reactor.class | ES::Projection.class)
  bus = ES::EventBus(ES::Reactor.class | ES::Projection.class).new(event_store: store, event_handlers: handlers)
  reactors.each { |reactor| bus.subscribe(SubOrderPlaced, reactor) }
  bus
end

private def subscriptions(store : ES::EventStore, bus, handlers, instance = UUID.v7.to_s) : ES::Subscriptions
  ES::Subscriptions.new(
    bus: bus, event_store: store, event_handlers: handlers, projection_database: nil,
    poll_interval: 5.milliseconds, rebalance_interval: 30.milliseconds,
    max_attempts: 3, retry_base_delay: 1.millisecond, retry_max_delay: 5.milliseconds,
    instance_id: instance,
  )
end

# Polls until the block is truthy, failing after `timeout`
private def eventually(timeout = 3.seconds, &block : -> Bool) : Nil
  deadline = Time.utc + timeout
  until block.call
    raise "condition not met within #{timeout}" if Time.utc > deadline
    sleep 5.milliseconds
  end
end

private def shipped(store : ES::EventStore) : Array(Int32)
  store.read_log(ES::EventStore::LogPosition::ZERO, handles: [SubOrderShipped.handle]).events.map(&.body["number"].as_i)
end

describe ES::Subscriptions do
  before_each do
    SubShipOrder.seen.clear
    SubShipOrder.failing = nil
    SubOrderLog.seen.clear
    SubShipmentLog.seen.clear
    {% for index in 1..4 %}
      SubCounter{{ index }}.seen.clear
    {% end %}
  end

  it "starts a new reactor at the head, so it never acts on history" do
    store = ES::EventStoreAdapters::InMemory.new
    handlers = sub_handlers
    store.append(placed(1))
    subs = subscriptions(store, sub_bus(store, handlers, SubShipOrder), handlers)

    subs.start
    store.append(placed(2))
    eventually { SubShipOrder.seen == [2] }
  ensure
    subs.try(&.stop)
  end

  it "starts at the beginning when configured to" do
    store = ES::EventStoreAdapters::InMemory.new
    handlers = sub_handlers
    store.append(placed(1))
    subs = subscriptions(store, sub_bus(store, handlers, SubShipOrder), handlers)

    subs.configure(SubShipOrder, start: :beginning).start
    store.append(placed(2))
    eventually { SubShipOrder.seen == [1, 2] }
  ensure
    subs.try(&.stop)
  end

  it "delivers every event once, committing the reactor's appends with its position" do
    store = ES::EventStoreAdapters::InMemory.new
    handlers = sub_handlers
    subs = subscriptions(store, sub_bus(store, handlers, SubShipOrder), handlers)
    subs.start

    (1..5).each { |number| store.append(placed(number)) }

    eventually { SubShipOrder.seen.size == 5 }
    SubShipOrder.seen.should eq([1, 2, 3, 4, 5])
    shipped(store).should eq([1, 2, 3, 4, 5])
    eventually { subs.status.first.caught_up? }
    status = subs.status.first
    status.name.should eq("reactor:SubShipOrder")
    status.status.should eq("running")
    status.owned?.should be_true
  ensure
    subs.try(&.stop)
  end

  it "rolls a failing reactor back, retries it with backoff and pauses it after max_attempts" do
    store = ES::EventStoreAdapters::InMemory.new
    handlers = sub_handlers
    subs = subscriptions(store, sub_bus(store, handlers, SubShipOrder), handlers)
    subs.start
    SubShipOrder.failing = 1

    store.append(placed(1))

    eventually { subs.status.first.status == "paused" }
    status = subs.status.first
    status.attempts.should eq(3)
    status.last_error.should eq("Exception: cannot ship order 1")
    # Each attempt's shipment rolled back with it
    shipped(store).should be_empty
    SubShipOrder.seen.should be_empty

    SubShipOrder.failing = nil
    subs.resume(SubShipOrder)
    eventually { SubShipOrder.seen == [1] }
    shipped(store).should eq([1])
    eventually { subs.status.first.status == "running" && subs.status.first.attempts == 0 }
  ensure
    subs.try(&.stop)
  end

  it "skips the event a reactor failed on when told to" do
    store = ES::EventStoreAdapters::InMemory.new
    handlers = sub_handlers
    subs = subscriptions(store, sub_bus(store, handlers, SubShipOrder), handlers)
    subs.start
    SubShipOrder.failing = 2

    (1..3).each { |number| store.append(placed(number)) }
    eventually { subs.status.first.status == "paused" }
    SubShipOrder.seen.should eq([1])

    subs.skip_failed_event(SubShipOrder)
    eventually { SubShipOrder.seen == [1, 3] }
    shipped(store).should eq([1, 3])
  ensure
    subs.try(&.stop)
  end

  it "pauses and resumes a handler" do
    store = ES::EventStoreAdapters::InMemory.new
    handlers = sub_handlers
    subs = subscriptions(store, sub_bus(store, handlers, SubShipOrder), handlers)
    subs.start

    subs.pause(SubShipOrder)
    eventually { subs.status.first.status == "paused" }
    sleep 50.milliseconds
    store.append(placed(1))
    sleep 50.milliseconds
    SubShipOrder.seen.should be_empty

    subs.resume(SubShipOrder)
    eventually { SubShipOrder.seen == [1] }
  ensure
    subs.try(&.stop)
  end

  it "shares subscriptions out between instances and delivers each event once" do
    store = ES::EventStoreAdapters::InMemory.new
    handlers = sub_handlers
    reactors = {SubCounter1, SubCounter2, SubCounter3, SubCounter4}
    first = subscriptions(store, sub_bus(store, handlers, *reactors), handlers)
    second = subscriptions(store, sub_bus(store, handlers, *reactors), handlers)
    first.start
    second.start

    eventually { first.status.count(&.owned?) == 2 && second.status.count(&.owned?) == 2 }
    (first.status.select(&.owned?).map(&.name) & second.status.select(&.owned?).map(&.name)).should be_empty

    (1..20).each { |number| store.append(placed(number)) }

    {% for index in 1..4 %}
      eventually { SubCounter{{ index }}.seen.size >= 20 }
      SubCounter{{ index }}.seen.should eq((1..20).to_a)
    {% end %}
  ensure
    first.try(&.stop)
    second.try(&.stop)
  end

  it "lets another instance take over the subscriptions of one that stops" do
    store = ES::EventStoreAdapters::InMemory.new
    handlers = sub_handlers
    reactors = {SubCounter1, SubCounter2}
    first = subscriptions(store, sub_bus(store, handlers, *reactors), handlers)
    second = subscriptions(store, sub_bus(store, handlers, *reactors), handlers)
    first.start
    second.start
    eventually { first.status.count(&.owned?) == 1 && second.status.count(&.owned?) == 1 }

    (1..5).each { |number| store.append(placed(number)) }
    first.stop
    (6..10).each { |number| store.append(placed(number)) }

    eventually { second.status.count(&.owned?) == 2 }
    eventually { SubCounter1.seen.size >= 10 && SubCounter2.seen.size >= 10 }
    SubCounter1.seen.should eq((1..10).to_a)
    SubCounter2.seen.should eq((1..10).to_a)
  ensure
    first.try(&.stop)
    second.try(&.stop)
  end

  it "partitions a handler by aggregate, keeping every aggregate's events in order" do
    store = ES::EventStoreAdapters::InMemory.new
    handlers = sub_handlers
    first = subscriptions(store, sub_bus(store, handlers, SubOrderLog), handlers).configure(SubOrderLog, partitions: 4)
    second = subscriptions(store, sub_bus(store, handlers, SubOrderLog), handlers).configure(SubOrderLog, partitions: 4)
    first.start
    second.start
    eventually { first.status.count(&.owned?) == 2 && second.status.count(&.owned?) == 2 }
    first.status.map(&.name).sort!.should eq((0..3).map { |index| "reactor:SubOrderLog##{index}/4" })

    aggregates = Array.new(8) { UUID.v7 }
    (1..5).each do |version|
      aggregates.each { |aggregate| store.append(placed(version, aggregate, version)) }
    end

    eventually { SubOrderLog.seen.values.sum(&.size) >= 40 }
    SubOrderLog.seen.size.should eq(8)
    SubOrderLog.seen.values.each(&.should(eq([1, 2, 3, 4, 5])))
  ensure
    first.try(&.stop)
    second.try(&.stop)
  end

  it "awaits a handler having processed a position" do
    store = ES::EventStoreAdapters::InMemory.new
    handlers = sub_handlers
    subs = subscriptions(store, sub_bus(store, handlers, SubShipOrder), handlers)
    subs.start

    store.append(placed(1))
    subs.await(SubShipOrder, store.log_head, timeout: 2.seconds).should be_true
    SubShipOrder.seen.should eq([1])

    subs.pause(SubShipOrder)
    eventually { subs.status.first.status == "paused" }
    sleep 50.milliseconds
    store.append(placed(2))
    subs.await(SubShipOrder, store.log_head, timeout: 50.milliseconds).should be_false
  ensure
    subs.try(&.stop)
  end

  it "resets a reactor to the beginning to process history again" do
    store = ES::EventStoreAdapters::InMemory.new
    handlers = sub_handlers
    subs = subscriptions(store, sub_bus(store, handlers, SubCounter1), handlers)
    subs.start
    store.append(placed(1))
    eventually { SubCounter1.seen == [1] }

    subs.reset(SubCounter1, to: :beginning)
    eventually { SubCounter1.seen == [1, 1] }
  ensure
    subs.try(&.stop)
  end

  it "lets one instance at a time hold a subscription's lock" do
    store = ES::SubscriptionStoreAdapters::InMemory.new

    store.try_lock("reactor:A").should be_true
    store.try_lock("reactor:A").should be_false
    store.try_lock("reactor:B").should be_true
    store.unlock("reactor:A")
    store.try_lock("reactor:A").should be_true
  end

  it "refuses to change a subscription's partitions in place" do
    store = ES::EventStoreAdapters::InMemory.new
    handlers = sub_handlers
    subs = subscriptions(store, sub_bus(store, handlers, SubCounter1), handlers)
    subs.start
    subs.stop

    repartitioned = subscriptions(store, sub_bus(store, handlers, SubCounter1), handlers).configure(SubCounter1, partitions: 2)
    expect_raises(ES::Exception::InvalidState, /another number of partitions \(reactor:SubCounter1\)/) { repartitioned.start }
  end

  it "refuses a configuration it cannot serve" do
    store = ES::EventStoreAdapters::InMemory.new
    handlers = sub_handlers
    subs = subscriptions(store, sub_bus(store, handlers, SubCounter1), handlers)

    expect_raises(ES::Exception::InvalidState, /not subscribed/) { subs.configure(SubCounter2) }
    expect_raises(ES::Exception::InvalidState, /partitions/) { subs.configure(SubCounter1, partitions: 0) }
    expect_raises(ES::Exception::InvalidState, /start/) { subs.configure(SubCounter1, start: :yesterday) }
    expect_raises(ES::Exception::InvalidState, /only applies to projections/) { subs.configure(SubCounter1, database: DBMock.open) }

    subs.status
    expect_raises(ES::Exception::InvalidState, /before the subscriptions are used/) { subs.configure(SubCounter1) }
  end

  it "refuses a handler of events not registered in the event handlers" do
    store = ES::EventStoreAdapters::InMemory.new
    handlers = ES::EventHandlers.new
    subs = subscriptions(store, sub_bus(store, handlers, SubCounter1), handlers)

    expect_raises(ES::Exception::InvalidState, /not registered/) { subs.start }
  end

  it "refuses a projection that fills itself on init" do
    store = ES::EventStoreAdapters::InMemory.new
    handlers = sub_handlers
    bus = ES::EventBus(ES::Reactor.class | ES::Projection.class).new(event_store: store, event_handlers: handlers)
    bus.subscribe(SubOrderPlaced, SubInitProjection)

    expect_raises(ES::Exception::InvalidState, /init: true/) { subscriptions(store, bus, handlers).start }
  end

  it "refuses a projection in the event store's schema" do
    store = ES::EventStoreAdapters::InMemory.new
    handlers = sub_handlers
    bus = ES::EventBus(ES::Reactor.class | ES::Projection.class).new(event_store: store, event_handlers: handlers)
    bus.subscribe(SubOrderPlaced, SubEventStoreProjection)

    expect_raises(ES::Exception::InvalidState, /no valid table name/) { subscriptions(store, bus, handlers).start }
  end

  it "can't start twice" do
    store = ES::EventStoreAdapters::InMemory.new
    handlers = sub_handlers
    subs = subscriptions(store, sub_bus(store, handlers, SubCounter1), handlers)
    subs.start

    expect_raises(ES::Exception::InvalidState, /started already/) { subs.start }
  ensure
    subs.try(&.stop)
  end

  describe "#catch_up" do
    it "processes every subscription in the calling fiber, down a chain of reactors" do
      store = ES::EventStoreAdapters::InMemory.new
      handlers = sub_handlers
      # The end of the chain is wired first, so it has its turn before the
      # shipments it handles are appended
      bus = ES::EventBus(ES::Reactor.class | ES::Projection.class).new(event_store: store, event_handlers: handlers)
      bus.subscribe(SubOrderShipped, SubShipmentLog)
      bus.subscribe(SubOrderPlaced, SubShipOrder)
      subs = subscriptions(store, bus, handlers)
      subs.catch_up

      store.append(placed(1))
      store.append(placed(2))
      subs.catch_up

      SubShipOrder.seen.should eq([1, 2])
      SubShipmentLog.seen.should eq([1, 2])
      shipped(store).should eq([1, 2])
      subs.status.all?(&.caught_up?).should be_true

      subs.catch_up
      SubShipOrder.seen.should eq([1, 2])
    end

    it "raises a handler's error, keeps nothing of the failed event, and goes on from there" do
      store = ES::EventStoreAdapters::InMemory.new
      handlers = sub_handlers
      subs = subscriptions(store, sub_bus(store, handlers, SubShipOrder), handlers)
      subs.catch_up
      SubShipOrder.failing = 2
      (1..3).each { |number| store.append(placed(number)) }

      expect_raises(Exception, /cannot ship order 2/) { subs.catch_up }
      SubShipOrder.seen.should eq([1])
      shipped(store).should eq([1])

      SubShipOrder.failing = nil
      subs.catch_up
      SubShipOrder.seen.should eq([1, 2, 3])
      shipped(store).should eq([1, 2, 3])
    end

    it "leaves a paused subscription alone" do
      store = ES::EventStoreAdapters::InMemory.new
      handlers = sub_handlers
      subs = subscriptions(store, sub_bus(store, handlers, SubShipOrder), handlers)
      subs.catch_up
      subs.pause(SubShipOrder)
      store.append(placed(1))

      subs.catch_up
      SubShipOrder.seen.should be_empty

      subs.resume(SubShipOrder)
      subs.catch_up
      SubShipOrder.seen.should eq([1])
    end

    it "saves how far a subscription read past events it doesn't handle" do
      store = ES::EventStoreAdapters::InMemory.new
      handlers = sub_handlers
      bus = ES::EventBus(ES::Reactor.class | ES::Projection.class).new(event_store: store, event_handlers: handlers)
      bus.subscribe(SubOrderShipped, SubShipmentLog)
      subs = subscriptions(store, bus, handlers)
      subs.catch_up
      (1..3).each { |number| store.append(placed(number)) }

      subs.catch_up
      subs.status.first.position.should eq(store.log_head)
    end

    it "raises when the reactors don't stop appending events that reach them again" do
      store = ES::EventStoreAdapters::InMemory.new
      handlers = sub_handlers
      bus = ES::EventBus(ES::Reactor.class | ES::Projection.class).new(event_store: store, event_handlers: handlers)
      bus.subscribe(SubOrderShipped, SubEndlessShipping)
      subs = subscriptions(store, bus, handlers)
      subs.configure(SubEndlessShipping, start: :beginning)
      store.append(SubOrderShipped.new(actor_id: nil, command_handler: "test", number: 0, aggregate_id: UUID.v7, aggregate_version: 1))

      expect_raises(ES::Exception::InvalidState, /did not catch up within/) { subs.catch_up(timeout: 100.milliseconds) }
    end

    it "refuses a subscription another instance is processing" do
      store = ES::EventStoreAdapters::InMemory.new
      handlers = sub_handlers
      running = subscriptions(store, sub_bus(store, handlers, SubShipOrder), handlers)
      running.start

      expect_raises(ES::Exception::InvalidState, /being processed by another instance/) do
        subscriptions(store, sub_bus(store, handlers, SubShipOrder), handlers).catch_up
      end
    ensure
      running.try(&.stop)
    end

    it "leaves subscriptions neither started nor caught up alone on stop" do
      store = ES::EventStoreAdapters::InMemory.new
      handlers = sub_handlers
      subs = subscriptions(store, sub_bus(store, handlers, SubCounter1), handlers)
      subs.stop
      subs.start
    ensure
      subs.try(&.stop)
    end

    it "can't be combined with start, nor run after stop" do
      store = ES::EventStoreAdapters::InMemory.new
      handlers = sub_handlers
      started = subscriptions(store, sub_bus(store, handlers, SubCounter1), handlers)
      started.start
      expect_raises(ES::Exception::InvalidState, /use await/) { started.catch_up }
      started.stop

      caught_up = subscriptions(store, sub_bus(store, handlers, SubCounter1), handlers)
      caught_up.catch_up
      caught_up.stop
      expect_raises(ES::Exception::InvalidState, /stopped/) { caught_up.catch_up }
      expect_raises(ES::Exception::InvalidState, /stopped/) { caught_up.start }
    ensure
      started.try(&.stop)
    end
  end
end
