module ES
  class EventBus(T)
    @subscriptions = Hash(ES::Event.class, Array(T)).new

    # Initializes the event bus with a connection to the event store, as well as the defined event handlers
    def initialize(
      @event_store : ES::EventStore = ES::Config.event_store,
      @event_handlers : ES::EventHandlers = ES::Config.event_handlers,
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

    # Subscribe an array of event handlers to an event
    def subscribe(event_class : ES::Event.class, handlers : Array(T))
      handlers.each do |r|
        subscribe(event_class, r)
      end
    end

    # Subscribe a single event handler to an event.
    #
    # The handler must declare it can consume the event — a projection by an
    # `apply` overload, a reactor by a typed `call`. Wiring an event to a handler
    # that cannot serve it would otherwise fail silently (the projection catch-all
    # swallows it) or at runtime mid-fan-out, so it is rejected here instead.
    def subscribe(event_class : ES::Event.class, handler : T)
      if !handler.handles?(event_class)
        raise ES::Exception::InvalidState.new(
          "'#{handler.name}' cannot be subscribed to '#{event_class.name}': it declares no handler for that event"
        )
      end

      if !@subscriptions.has_key?(event_class)
        @subscriptions[event_class] = Array(T).new
      end

      s = @subscriptions[event_class]
      s.push(handler) unless s.includes?(handler)
      s
    end

    # Check if handler is subscribed to event
    def subscribed?(event_class : ES::Event.class, handler : T)
      return false if !@subscriptions.has_key?(event_class)

      @subscriptions[event_class].includes?(handler)
    end

    # Unsubscribe a single event handler from an event
    def unsubscribe(event_class : ES::Event.class, handler : T)
      return true if !@subscriptions.has_key?(event_class) # TODO: Check if exception is more reasonable

      s = @subscriptions[event_class]
      s.delete(handler)
    end

    # The full routing table: which handlers each event fans out to. Useful when
    # a single event drives many workflows and the wiring file has grown long.
    def routes : Hash(ES::Event.class, Array(T))
      @subscriptions.transform_values(&.dup)
    end
  end
end
