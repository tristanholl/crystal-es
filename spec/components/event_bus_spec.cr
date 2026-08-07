require "../spec_helper"

describe ES::EventBus do
  it "can publish events" do
    eb = ES::EventBus(ES::Reactor.class).new(
      event_store: ES::EventStoreAdapters::InMemory.new,
      event_handlers: ES::EventHandlers.new
    )

    eb.publish(DummyEvent.new)
  end

  it "can subscribe" do
    eb = ES::EventBus(ES::Reactor.class).new(
      event_store: ES::EventStoreAdapters::InMemory.new,
      event_handlers: ES::EventHandlers.new
    )

    eb.subscribe(DummyEvent, DummyReactor)
    eb.subscribed?(DummyEvent, DummyReactor).should eq(true)
  end

  it "can unsubscribe" do
    eb = ES::EventBus(ES::Reactor.class).new(
      event_store: ES::EventStoreAdapters::InMemory.new,
      event_handlers: ES::EventHandlers.new
    )

    eb.subscribe(DummyEvent, DummyReactor)
    eb.unsubscribe(DummyEvent, DummyReactor)
    eb.subscribed?(DummyEvent, DummyReactor).should eq(false)
  end

  it "delivers published events to subscribed reactors" do
    eb = ES::EventBus(ES::Reactor.class).new(
      event_store: ES::EventStoreAdapters::InMemory.new,
      event_handlers: ES::EventHandlers.new
    )

    DummyReactor.invocations = 0
    eb.subscribe(DummyEvent, DummyReactor)
    eb.publish(DummyEvent.new)

    DummyReactor.invocations.should eq(1)
  end

  it "refuses to subscribe a handler to an event it does not declare" do
    eb = ES::EventBus(ES::Reactor.class).new(
      event_store: ES::EventStoreAdapters::InMemory.new,
      event_handlers: ES::EventHandlers.new
    )

    expect_raises(ES::Exception::InvalidState, /declares no handler for that event/) do
      eb.subscribe(OtherDummyEvent, DummyReactor)
    end
  end

  it "subscribed? returns false for an event nobody subscribed to" do
    eb = ES::EventBus(ES::Reactor.class).new(
      event_store: ES::EventStoreAdapters::InMemory.new,
      event_handlers: ES::EventHandlers.new
    )

    eb.subscribed?(DummyEvent, DummyReactor).should eq(false)
  end

  it "does not deliver twice when the same handler is subscribed twice" do
    eb = ES::EventBus(ES::Reactor.class).new(
      event_store: ES::EventStoreAdapters::InMemory.new,
      event_handlers: ES::EventHandlers.new
    )

    DummyReactor.invocations = 0
    eb.subscribe(DummyEvent, DummyReactor)
    eb.subscribe(DummyEvent, DummyReactor)
    eb.publish(DummyEvent.new)

    DummyReactor.invocations.should eq(1)
  end

  it "exposes the routing table" do
    eb = ES::EventBus(ES::Reactor.class).new(
      event_store: ES::EventStoreAdapters::InMemory.new,
      event_handlers: ES::EventHandlers.new
    )

    eb.subscribe(DummyEvent, [DummyReactor, MultiEventReactor] of ES::Reactor.class)
    eb.subscribe(OtherDummyEvent, MultiEventReactor)

    routes = eb.routes
    routes[DummyEvent].should eq([DummyReactor, MultiEventReactor])
    routes[OtherDummyEvent].should eq([MultiEventReactor])
  end
end

# The union ES::Config.event_bus= requires, and that examples/ uses — previously
# untested, though it is the only shape a real application constructs.
describe "ES::EventBus with a mixed reactor/projection union" do
  it "routes one event to both a reactor and a projection" do
    eb = ES::EventBus(ES::Reactor.class | ES::Projection.class).new(
      event_store: ES::EventStoreAdapters::InMemory.new,
      event_handlers: ES::EventHandlers.new
    )
    ES::Config.projection_database = DBMock.open

    DummyReactor.invocations = 0
    eb.subscribe(DummyEvent, DummyReactor)
    eb.subscribe(DummyEvent, TestProjection)
    eb.publish(DummyEvent.new)

    DummyReactor.invocations.should eq(1)
    eb.routes[DummyEvent].size.should eq(2)
  end

  it "rejects a projection that declares no apply for the event" do
    eb = ES::EventBus(ES::Reactor.class | ES::Projection.class).new(
      event_store: ES::EventStoreAdapters::InMemory.new,
      event_handlers: ES::EventHandlers.new
    )

    expect_raises(ES::Exception::InvalidState, /declares no handler for that event/) do
      eb.subscribe(OtherDummyEvent, TestApplyDSLProjection)
    end
  end
end
