require "../spec_helper"

describe "ES::CommandHandler" do
  it "handles a typed command" do
    handler = DummyCommandHandler.new(
      event_store: ES::EventStoreAdapters::InMemory.new,
      event_handlers: ES::EventHandlers.new
    )

    handler.handle(DummyCommand.new)
    handler.handled.should be_true
  end
end
