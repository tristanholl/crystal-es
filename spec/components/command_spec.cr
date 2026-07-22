require "../spec_helper"

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

  it "subclass can define its own call method" do
    dc = DummyCommand.new(
      event_store: ES::EventStoreAdapters::InMemory.new,
      event_handlers: ES::EventHandlers.new
    )

    dc.call
    dc.test_attribute.should be_true
  end
end
