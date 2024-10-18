module ES
  abstract class Command
    abstract def call

    @aggregate_id : UUID
    @trigger_event : ES::Event?

    # Initialize with a random aggregate ID
    def initialize(
      @event_store : ES::EventStore = ES::Config.event_store,
      @event_handlers : ES::EventHandlers = ES::Config.event_handlers
    )
      @aggregate_id = UUID.v7
    end

    # Initialize with a provided aggregate ID
    def initialize(
      @aggregate_id : UUID,
      @event_store : ES::EventStore = ES::Config.event_store,
      @event_handlers : ES::EventHandlers = ES::Config.event_handlers
    )
    end

    # Execute command with trigger event parameter
    def call(event : ES::Event)
      @aggregate_id = event.header.aggregate_id
      @trigger_event = event

      call
    end

    # Placeholder for subclasses
    def call
      raise ES::Exception::NotImplemented.new("The command class does not properly implement the call() function")
    end
  end
end
