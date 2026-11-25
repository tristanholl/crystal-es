# Recommended project structure

crystal-es doesn't impose a layout. The one below scales from a single domain to many. It groups code by domain rather than by building block, puts one building block in each file, and keeps all the wiring in one place.

```
src/
  domains/
    orders/
      events/
        order_placed.cr           # define_event, one per file
        order_cancelled.cr
      aggregates/
        order.cr                  # ES::Aggregate
      decisions/
        open_orders_for_customer.cr  # ES::DecisionProjection, one question each
      commands/
        place_order.cr            # ES::Command and its ES::CommandHandler
        cancel_order.cr
      reactors/
        on_payment_captured.cr    # ES::Reactor: one workflow step
      projections/
        orders_list.cr            # define_projection, table "orders.orders_list"
    payments/
      ...
  wiring/
    config.cr                     # ES::Config: stores, encryption, tag hasher
    event_handlers.cr             # register every event class
    event_bus.cr                  # the routing: event → reactors and projections
  app.cr                          # boot: setup, then start subscriptions
spec/
  domains/
    orders/                       # mirrors src/, against the in-memory adapters
```

The [`financial-transaction`](../examples/financial-transaction) and [`course-subscription`](../examples/course-subscription) examples use the same folders for a single domain, with all the wiring in `example.cr`.

## Inside a domain

| Folder | Holds | Name after |
|---|---|---|
| `events/` | Facts, declared with `define_event` | What happened, in the past tense: `order_placed.cr` |
| `aggregates/` | State rebuilt from one aggregate's stream, where a rule belongs to a single entity | The entity: `order.cr` |
| `decisions/` | Decision projections, where a rule spans several entities (see [Decision projections](consistency.md#decision-projections)) | The question it answers: `course_capacity.cr` |
| `commands/` | A command and its handler, in the same file | The intent, imperative: `place_order.cr` |
| `reactors/` | One workflow step: an event in, a command out | The event that triggers it: `on_payment_captured.cr` (`OnPaymentCaptured`) |
| `projections/` | Read models for queries and screens | What it lists or shows: `orders_list.cr` |

A domain needs only the folders it uses. One that decides with tags may have no `aggregates/`, and one that only reacts may have no `projections/`.

- **The event handle is the contract, not the class.** Stored events find their class through `event_handle` (and carry `aggregate_type`). You can move a class between files, domains or namespaces, but never change its handle: events already stored would no longer find it.
- **Namespace classes by domain**, e.g. `Orders::OrderPlaced`, so two domains can each have a `Created` event or a `Cancel` command.
- **Give each domain its own Postgres schema** for its projections (`"orders.orders_list"`). `setup` doesn't create schemas, so create them in your migrations.

## Between domains

- **Events are a domain's public interface.** Other domains may react to them. Its aggregates, decisions and handlers stay internal.
- **A reactor lives in the domain whose command it issues.** `payments/reactors/on_order_placed.cr` reacts to an `orders` event and starts a `payments` command. The emitting domain doesn't need to know who listens.
- **A command handler doesn't call another domain's handler.** If placing an order should start a payment, the payment is a reactor's job. Each handler then appends within one consistency boundary, and the workflow stays visible in `event_bus.cr`.
- **Tags shared between domains,** such as `customer_id`, must be declared the same way everywhere, in particular `hashed:`. The compiler warns when a key is hashed in one event and not in another.

## Wiring

Keep the wiring out of the domains, so you can read it in one go:

- **`config.cr`** builds the key store, `ES::Config.encryption` and `ES::Config.tag_hasher`, then the event store. The tag hasher must be configured before the event store, which reads it when it's constructed.
- **`event_handlers.cr`** registers every event class with `ES::Config.event_handlers`. An event whose class isn't registered can't be read back.
- **`event_bus.cr`** subscribes reactors and projections to events. It's the one place that shows an event's full fan-out, and `subscribe` checks every route at boot.
- **`app.cr`** runs `setup` on the key store, the event store and each projection, then starts [subscriptions](subscriptions.md) on every instance.

## Specs

Mirror `src/domains/` under `spec/domains/`, and run the domain specs against the in-memory event store and key store: they implement the same semantics as Postgres. Test a command handler by appending its preconditions as events, calling `handle`, and asserting on the events it appended. Test reactors and projections through the wiring: append events, call `ES::Subscriptions#catch_up`, and assert on what the handlers did (see [Specs and scripts](subscriptions.md#specs-and-scripts)). Keep a smaller set of specs against Postgres for the wiring: setup, projections and subscriptions.
