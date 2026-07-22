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
end
