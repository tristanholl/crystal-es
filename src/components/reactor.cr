module ES
  # A Reactor consumes events from the EventBus and reacts to them, typically by
  # constructing a Command and calling its CommandHandler directly. It is the one
  # bridge from an event back to a command — each workflow step is a named Reactor.
  #
  # Declare the event a reactor listens to with `reacts_to`, then implement a
  # typed `call` for it:
  #
  # ```
  # class OnOrderPlaced < ES::Reactor
  #   reacts_to OrderPlaced
  #
  #   def call(event : OrderPlaced)
  #     ReserveStockHandler.new(event_store: @event_store).handle(
  #       ReserveStock.new(aggregate_id: event.header.aggregate_id)
  #     )
  #   end
  # end
  # ```
  abstract class Reactor
    def initialize(
      @event_store : ES::EventStore = ES::Config.event_store,
      @event_handlers : ES::EventHandlers = ES::Config.event_handlers,
    )
    end

    # Entry point invoked by the EventBus with the published event.
    abstract def call(event : ES::Event)

    # Bridges the erased event handed over by the EventBus to the typed `call`
    # the reactor implements. Safe because the bus only delivers subscribed events.
    macro reacts_to(event_type)
      def call(event : ES::Event)
        call(event.as({{event_type}}))
      end
    end
  end
end
