module ES
  # A Reactor consumes events from the EventBus and reacts to them, typically by
  # constructing a Command and calling its CommandHandler directly. It is the one
  # bridge from an event back to a command — each workflow step is a named Reactor.
  #
  # A reactor declares the events it handles by defining a typed `call` for each,
  # exactly as a Projection declares its events with typed `apply` overloads:
  #
  # ```
  # class OnOrderPlaced < ES::Reactor
  #   def call(event : OrderPlaced)
  #     ReserveStockHandler.new(event_store: @event_store).handle(
  #       ReserveStock.new(aggregate_id: event.header.aggregate_id)
  #     )
  #   end
  # end
  # ```
  #
  # Routing stays in one place — the EventBus wiring — so the full fan-out of an
  # event across workflows is readable in a single file. `EventBus#subscribe`
  # checks this declaration and refuses a subscription the reactor cannot serve,
  # turning a wiring mistake into a startup error.
  abstract class Reactor
    include ES::EventDeclaration

    # A reactor declares the events it consumes with typed `call` overloads.
    macro inherited
      macro finished
        define_handles?("call")
      end
    end

    def initialize(
      @event_store : ES::EventStore = ES::Config.event_store,
      @event_handlers : ES::EventHandlers = ES::Config.event_handlers,
    )
    end

    # Catch-all for events the reactor declares no typed `call` for. Unlike a
    # projection — which may legitimately ignore an event — a reactor reaching
    # this method means a workflow step was dropped, so it raises rather than
    # failing silently. `EventBus#subscribe` normally prevents this at boot.
    def call(event : ES::Event)
      raise ES::Exception::InvalidState.new(
        "'#{self.class.name}' received '#{event.class.name}' but declares no `call` overload for it"
      )
    end
  end
end
