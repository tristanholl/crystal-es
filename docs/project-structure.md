# Project structure

For larger projects, the following vertical-slice layout works well:

```
src/
  domains/
    orders/
      aggregates/
        order.cr                # ES::Aggregate
      commands/
        place_order.cr          # ES::Command + its ES::CommandHandler
        cancel_order.cr
      events/
        order_placed.cr         # define_event
        order_cancelled.cr
      reactors/
        on_payment_captured.cr  # ES::Reactor — event → next command
      projections/
        orders_list.cr          # define_projection
    payments/
      ...
  shared/
    ...
  config.cr                     # ES::Config.configure: stores, event bus, encryption
  event_bus.cr                  # register event types, subscribe reactors and projections
```

Keep each command next to its handler, and give each reactor one workflow step, named after the event that triggers it (`On<Event>`). Wire the routing in one place (`event_bus.cr`) so you can see an event's full fan-out at a glance. The [`financial-transaction`](../examples/financial-transaction) example uses the same layout, flattened to a single domain.
