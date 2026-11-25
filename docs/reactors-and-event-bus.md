# Reactors and the event bus

## Reactor

`ES::Reactor` consumes events from the `EventBus` and reacts to them — typically by constructing a command and calling its handler directly. It is the one bridge from an event back to a command; each step of a workflow is a named reactor. Declare the events it handles by defining a typed `call` for each, the same way a projection declares its events with typed `apply` overloads:

```crystal
class OnOrderPlaced < ES::Reactor
  def call(event : OrderPlaced)
    ReserveStockHandler.new(event_store: @event_store).handle(
      ReserveStock.new(aggregate_id: event.header.aggregate_id)
    )
  end
end
```

A reactor may declare several events by defining one `call` per event. Routing itself stays in the `EventBus` wiring, so the full fan-out of an event across workflows is readable in a single place; `subscribe` checks this declaration and refuses a subscription the reactor cannot serve.

Reaching a reactor with an event it declares no `call` for raises `ES::Exception::InvalidState`. A projection may legitimately ignore an event, but a reactor doing so means a workflow step was silently dropped.

## Event Bus

`ES::EventBus` fans out published events to all registered subscribers (reactors and projections). It never runs business logic itself and never touches a command handler — reactors reach handlers by a direct call.

```crystal
bus = ES::EventBus(ES::Reactor.class | ES::Projection.class).new
bus.subscribe(OrderPlaced, OnOrderPlaced)     # a reactor
bus.subscribe(OrderPlaced, OrdersProjection)  # a projection

bus.publish(event)
```

This wiring is the single place where workflows are defined — one event may fan out to many handlers, and that fan-out is visible nowhere else. `subscribe` raises `ES::Exception::InvalidState` if the handler declares no `call`/`apply` for the event, so a wiring mistake surfaces at boot rather than as a silently swallowed event.

`bus.routes` returns the full routing table when the wiring file has grown long:

```crystal
bus.routes # => {OrderPlaced => [OnOrderPlaced, OrdersProjection], ...}
```

The bus defines the routing; [Subscriptions](subscriptions.md) deliver the events along it. `ES::Subscriptions` reads `bus.routes` once, when it is configured or started, and turns every handler into a subscription that receives all the events it is subscribed to, in order. So finish the wiring before starting them.

`publish` runs every subscriber of an event at once, in the calling process, one after another, with no saved position and no retries: an exception stops the subscribers after it, and an event published while the process dies reaches no one. Don't use it in production next to subscriptions, or every handler runs twice. It remains handy where none of that matters, such as a quick script. In specs, prefer `ES::Subscriptions#catch_up` (see [Specs and scripts](subscriptions.md#specs-and-scripts)): it delivers what was appended along the same routes, with the guarantees production has, and without a database on the in-memory event store.
