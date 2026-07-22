module ES
  # A CommandHandler executes a single business operation described by a Command.
  #
  # It is a plain object: construct it and call `handle` directly. The calls is 
  # synchronous so invariant violations surface as a raised exception
  # the endpoint can answer with; a Reactor calls it the same way in response to
  # an event. There is no dispatcher in between.
  #
  # The handler is generic over its command type `C`, so `handle(command : C)` is
  # checked by the compiler — no registry and no runtime cast are involved.
  abstract class CommandHandler(C)
    def initialize(
      @event_store : ES::EventStore = ES::Config.event_store,
      @event_handlers : ES::EventHandlers = ES::Config.event_handlers,
    )
    end

    # Hydrate the target aggregate, enforce state invariants, append events.
    abstract def handle(command : C)
  end
end
