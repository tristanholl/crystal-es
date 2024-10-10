module ES
  class Eventbus(T)
    @subscriptions = Hash(ES::Event.class, Array(T)).new

    def initialize(
      @event_store : ES::EventStore = ES::Config.event_store,
      @event_handlers : ES::EventHandlers = ES::Config.event_handlers
    )
    end

    # TODO: Currently blocking, might be a candidate for async processing
    def publish(event : ES::Event) : Bool
      return true if !@subscriptions.has_key?(event.class) # TODO: Check if exception is more reasonable

      @subscriptions[event.class].each do |receiver|
        receiver.new(event_store: @event_store, event_handlers: @event_handlers).call(event)
      end

      true
    end

    def subscribe(event_class : ES::Event.class, handlers : Array(T))
      handlers.each do |r|
        subscribe(event_class, r)
      end
    end

    def subscribe(event_class : ES::Event.class, handler : T)
      if !@subscriptions.has_key?(event_class)
        @subscriptions[event_class] = Array(T).new
      end

      s = @subscriptions[event_class]
      s.push(handler)
    end

    def unsubscribe(event_class : ES::Event.class, handler : T)
      return true if !@subscriptions.has_key?(event_class) # TODO: Check if exception is more reasonable

      s = @subscriptions[event_class]
      s.delete(handler)
    end
  end
end
