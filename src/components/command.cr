module ES
  # Base class for behavioral commands (pre-Phase-5 style).
  # As of v0.7.0 this carries no abstract contract — use ES::Decider +
  # ES::CommandHandler for new code.  This class is kept for source
  # compatibility with existing subclasses during the transition window.
  class Command
    @aggregate_id : UUID
    @trigger_event : ES::Event?

    # Initialize with a random aggregate ID
    def initialize(
      @event_store : ES::EventStore = ES::Config.event_store,
      @event_handlers : ES::EventHandlers = ES::Config.event_handlers,
    )
      @aggregate_id = UUID.v7
    end

    # Initialize with a provided aggregate ID
    def initialize(
      @aggregate_id : UUID,
      @event_store : ES::EventStore = ES::Config.event_store,
      @event_handlers : ES::EventHandlers = ES::Config.event_handlers,
    )
    end
  end
end
