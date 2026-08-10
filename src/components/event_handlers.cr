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
    #
    # A shredded event has no body left to build from, so callers decide what to do
    # about it *before* calling: an aggregate raises or bumps the version, a
    # projection skips. Reaching here with one is a bug, hence the guard.
    def materialize(stored : ES::EventStore::Event, header : ES::Event::Header) : ES::Event
      raise ES::Exception::KeyDestroyed.new("Event '#{header.event_id}' cannot be materialized: its encryption key was destroyed") if stored.shredded?

      event_class(header.event_handle).new(header, stored.body)
    end

    # :ditto:
    def materialize(stored : ES::EventStore::Event) : ES::Event
      materialize(stored, ES::Event::Header.from_json(stored.header.to_json))
    end
  end
end
