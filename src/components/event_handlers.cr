module ES
  class EventHandlers
    @event_handles = Hash(String, ES::Event.class).new

    # Register a new event handler
    def register(event_class : ES::Event.class)
      h = event_class.handle
      raise ES::Exception::Conflict.new("handle '#{h}' already registered") if @event_handles.has_key?(h)

      @event_handles[h] = event_class
    end

    # Return the class for a given event handle
    def event_class(handle : String) : ES::Event.class
      raise ES::Exception::NotFound.new("handle '#{handle}' not registered") unless @event_handles.has_key?(handle)
      @event_handles[handle]
    end
  end
end
