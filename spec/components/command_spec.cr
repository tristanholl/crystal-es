require "../spec_helper"

class IncompleteDummyCommand < ES::Command; end

describe ES::Command do
  it "initializes with event store and handlers" do
    DummyCommand.new(
      event_store: ES::EventStoreAdapters::InMemory.new,
      event_handlers: ES::EventHandlers.new
    )
  end

  it "initializes with aggregate_id, event store and handlers" do
    DummyCommand.new(
      aggregate_id: UUID.v7,
      event_store: ES::EventStoreAdapters::InMemory.new,
      event_handlers: ES::EventHandlers.new
    )
  end

  it "Raises NotImplemented error if the child does not properly implement a call() method" do
    dc = IncompleteDummyCommand.new(
      event_store: ES::EventStoreAdapters::InMemory.new,
      event_handlers: ES::EventHandlers.new
    )

    expect_raises(ES::Exception::NotImplemented) do
      dc.call(DummyEvent.new)
    end
  end

  it "does not raise exception for properly implemented call() method" do
    dc = DummyCommand.new(
      event_store: ES::EventStoreAdapters::InMemory.new,
      event_handlers: ES::EventHandlers.new
    )

    dc.call(DummyEvent.new)
    dc.test_attribute.should be_true
  end
end
