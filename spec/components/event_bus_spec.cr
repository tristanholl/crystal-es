require "../spec_helper"

class IncompleteDummyCommand < ES::Command; end

describe ES::EventBus do
  it "can publish events" do
    eb = ES::EventBus(ES::Command.class).new(
      event_store: ES::EventStoreAdapters::InMemory.new,
      event_handlers: ES::EventHandlers.new
    )

    eb.publish(DummyEvent.new)
  end

  it "can subscribe" do
    eb = ES::EventBus(ES::Command.class).new(
      event_store: ES::EventStoreAdapters::InMemory.new,
      event_handlers: ES::EventHandlers.new
    )

    eb.subscribe(DummyEvent, DummyCommand)
    eb.subscribed?(DummyEvent, DummyCommand).should eq(true)
  end

  it "can unsubscribe" do
    eb = ES::EventBus(ES::Command.class).new(
      event_store: ES::EventStoreAdapters::InMemory.new,
      event_handlers: ES::EventHandlers.new
    )

    eb.subscribe(DummyEvent, DummyCommand)
    eb.unsubscribe(DummyEvent, DummyCommand)
    eb.subscribed?(DummyEvent, DummyCommand).should eq(false)
  end

  it "processes event to handler" do
    eb = ES::EventBus(ES::Command.class).new(
      event_store: ES::EventStoreAdapters::InMemory.new,
      event_handlers: ES::EventHandlers.new
    )

    event = DummyEvent.new
    eb.subscribe(DummyEvent, IncompleteDummyCommand)
    expect_raises(ES::Exception::NotImplemented) do
      eb.publish(DummyEvent.new)
    end
  end
end
