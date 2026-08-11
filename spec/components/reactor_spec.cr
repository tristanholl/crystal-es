require "../spec_helper"

describe "ES::Reactor" do
  it "reacts to its event through the erased entry point" do
    reactor = DummyReactor.new(
      event_store: ES::EventStoreAdapters::InMemory.new,
      event_handlers: ES::EventHandlers.new
    )

    DummyReactor.invocations = 0
    # The EventBus hands over an ES::Event; Crystal dispatches on the runtime type
    # to the typed `call` the reactor declares
    reactor.call(DummyEvent.new.as(ES::Event))
    DummyReactor.invocations.should eq(1)
  end

  it "dispatches each declared event to its own typed call" do
    reactor = MultiEventReactor.new(
      event_store: ES::EventStoreAdapters::InMemory.new,
      event_handlers: ES::EventHandlers.new
    )

    MultiEventReactor.seen = [] of String
    reactor.call(DummyEvent.new.as(ES::Event))
    reactor.call(OtherDummyEvent.new.as(ES::Event))

    MultiEventReactor.seen.should eq(["DummyEvent", "OtherDummyEvent"])
  end

  it "reports the events it declares" do
    DummyReactor.handles?(DummyEvent).should be_true
    DummyReactor.handles?(OtherDummyEvent).should be_false

    MultiEventReactor.handles?(DummyEvent).should be_true
    MultiEventReactor.handles?(OtherDummyEvent).should be_true
  end

  it "raises on an undeclared event rather than dropping it silently" do
    reactor = DummyReactor.new(
      event_store: ES::EventStoreAdapters::InMemory.new,
      event_handlers: ES::EventHandlers.new
    )

    expect_raises(ES::Exception::InvalidState, /declares no `call` overload/) do
      reactor.call(OtherDummyEvent.new.as(ES::Event))
    end
  end
end
