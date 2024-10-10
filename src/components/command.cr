module ES
  abstract class Command
    abstract def call

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

    def call(event : ES::Event)
      @aggregate_id = event.header.aggregate_id
      @trigger_event = event

      call
    end

    def call
      # TODO: Raise not implemented exception
    end
  end
end
