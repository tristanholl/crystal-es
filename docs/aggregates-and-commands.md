# Aggregates, commands and command handlers

## Aggregate

`ES::Aggregate` reconstructs domain state from its event history. Each aggregate defines a `State` struct and a set of `apply` overloads — one per event type.

```crystal
class Order < ES::Aggregate
  struct State
    property placed : Bool = false
    property amount : Int64 = 0_i64
  end

  def apply(event : OrderPlaced)
    @state.placed = true
    @state.amount = event.body.amount
  end
end
```

Call `Order.hydrate(aggregate_id, event_store)` to reconstruct an aggregate from persisted events.

## Command

`ES::Command` is a pure data record expressing an intent to change state. Following strict event sourcing, it carries only the target aggregate and its payload — it has no behavior.

```crystal
struct PlaceOrder < ES::Command
  getter amount : Int64

  def initialize(@aggregate_id : UUID, @amount : Int64)
  end
end
```

## Command Handler

`ES::CommandHandler(C)` encapsulates a single business operation. It is generic over the command type `C` it processes, so `handle(command : C)` is checked by the compiler. It hydrates the relevant aggregate, enforces state invariants, and appends new events.

A handler is a plain object — construct it and call `handle` directly. From an API endpoint that call is synchronous, so an invariant violation raises right where you can turn it into a response:

```crystal
class PlaceOrderHandler < ES::CommandHandler(PlaceOrder)
  def handle(command : PlaceOrder)
    order = Order.new(command.aggregate_id, event_store: @event_store)
    order.hydrate
    raise ES::Exception::InvalidState.new("already placed") if order.state.placed

    @event_store.append(OrderPlaced.new(
      aggregate_id: command.aggregate_id,
      body: OrderPlaced::Body.new(amount: command.amount)
    ))
  end
end

# In an API controller — invariant failures surface synchronously
PlaceOrderHandler.new.handle(PlaceOrder.new(aggregate_id: id, amount: 500_i64))
```
