module ES
  module Config
    extend self

    class_property version : String = "unknown"

    def event_store=(param : ES::EventStore)
      @@event_store = param
    end

    def event_store : ES::EventStore
      e = @@event_store
      raise "No default eventstore registered" if e.nil?
      e
    end

    def event_handlers=(param : ES::EventHandlers)
      @@event_handlers = param
    end

    def event_handlers : ES::EventHandlers
      h = @@event_handlers
      raise "No default event handlers registered" if h.nil?
      h
    end

    def event_bus=(param : ES::EventBus(ES::Command.class | ES::Projection.class))
      @@eventbus = param
    end

    def event_bus : ES::EventBus
      eb = @@eventbus
      raise "No eventbus registered" if eb.nil?
      eb
    end
  end
end
