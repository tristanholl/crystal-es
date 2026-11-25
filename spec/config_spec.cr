require "./spec_helper"

describe ES::Config do
  describe ".configure" do
    it "sets the values given in the block, in order" do
      handlers = ES::EventHandlers.new
      store = ES::EventStoreAdapters::InMemory.new
      bus = nil

      ES::Config.configure do |config|
        config.event_handlers = handlers
        config.event_store = store
        created = ES::EventBus(ES::Reactor.class | ES::Projection.class).new
        config.event_bus = created
        bus = created
      end

      ES::Config.event_handlers.should be(handlers)
      ES::Config.event_store.should be(store)
      ES::Config.event_bus.should be(bus)
    end
  end
end
