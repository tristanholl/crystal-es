module ES
  class EventHandlers
    @event_handles = Hash(String, ES::Event.class).new

    # Register a new event handler
    def register(event_class : ES::Event.class)
      h = event_class.handle
      raise ES::Exception::Conflict.new("handle '#{h}' already registered") if @event_handles.has_key?(h)

      @event_handles[h] = event_class
    end

    # Return whether a handle is registered
    def registered?(handle : String) : Bool
      @event_handles.has_key?(handle)
    end

    # Return the class for a given event handle
    def event_class(handle : String) : ES::Event.class
      raise ES::Exception::NotFound.new("handle '#{handle}' not registered") unless @event_handles.has_key?(handle)
      @event_handles[handle]
    end

    # Rebuilds a typed event from a stored one.
    #
    # Aggregates and projections both need this, so it lives here — the one place
    # that already knows how to get from a handle to a class.
    def materialize(stored : ES::EventStore::Event, header : ES::Event::Header) : ES::Event
      # Without this, the body class would fail on JSON null with a parse error
      # that says nothing about why the body is missing.
      raise ES::Exception::InvalidState.new("Event '#{header.event_id}' cannot be materialized: its body was erased with its encryption key") if stored.body_erased?

      event_class(header.event_handle).new(header, stored.body)
    end

    # :ditto:
    def materialize(stored : ES::EventStore::Event) : ES::Event
      materialize(stored, ES::Event::Header.from_json(stored.header.to_json))
    end
  end
end
