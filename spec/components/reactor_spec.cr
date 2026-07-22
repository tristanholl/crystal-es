require "../spec_helper"

describe "ES::Reactor" do
  it "initializes with event store and handlers" do
    DummyReactor.new(
      event_store: ES::EventStoreAdapters::InMemory.new,
      event_handlers: ES::EventHandlers.new
    )
  end

  it "reacts to its event through the erased entry point" do
    reactor = DummyReactor.new(
      event_store: ES::EventStoreAdapters::InMemory.new,
      event_handlers: ES::EventHandlers.new
    )

    DummyReactor.invocations = 0
    # The EventBus hands over an ES::Event; `reacts_to` bridges it to the typed call
    reactor.call(DummyEvent.new.as(ES::Event))
    DummyReactor.invocations.should eq(1)
  end
end
