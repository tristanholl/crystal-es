# crystal-es

An event sourcing library for Crystal

[![crystal-es (CI)](https://github.com/tristanholl/crystal-es/actions/workflows/ci.yml/badge.svg)](https://github.com/tristanholl/crystal-es/actions/workflows/ci.yml)

## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     crystal-es:
       github: tristanholl/crystal-es
   ```

2. Run `shards install`

## Overview

`crystal-es` is an event sourcing foundation for Crystal applications. It is optimized for PostgreSQL as event store, queue, and projection database, and was originally extracted from an open-source core-banking project.

The library provides:
- **Events** — immutable facts with a type-safe DSL
- **Aggregates** — reconstruct domain state by replaying events
- **Decision** — a pure result type (`Accepted(events)` / `Rejected(reason)`)
- **Decider** — pure functions: `decide(command, state) → Decision` and `evolve(state, event) → state`
- **CommandHandler** — the generic impure shell: read → fold → decide → append
- **DcbHandler** — DCB-ready handler: tag-query read → fold → decide → conditional append
- **Projections** — read models built from event streams, with a schema DSL and drift detection
- **Event Bus** — fan-out published events to registered handlers
- **Adapters** — PostgreSQL and in-memory implementations for event stores and queues

A complete working example lives in [`./examples/financial-transaction`](./examples/financial-transaction).

---

## Core Design

Three roles separate concerns:

| Role | Pure? | Contract |
|------|-------|----------|
| **Command** | yes | Data record — intent only, no behaviour |
| **Decider** | yes | `decide(cmd, state) → Decision(E)` · `evolve(state, event) → state` |
| **Handler** | no  | Read store → fold via `evolve` → call `decide` → append |

Two invariants hold at every layer boundary:

1. `evolve` and `decide` never read or write the event store.
2. The decider is **boundary-agnostic**: whether state was assembled from one aggregate stream or from a tag-query (DCB) is the handler's concern, not the decider's.

---

## Components

### Event

`ES::Event` is the base class for all domain events. Each event carries a **Header** (metadata) and a **Body** (event-specific payload).

#### Event DSL

The `define_event` macro removes the boilerplate. It generates the full event class, the `Body` struct with JSON serialization, and registers the handle automatically.

```crystal
define_event("order", "order_placed") do
  attribute :order_id, UUID
  attribute :amount,   Int64
  attribute :currency, String, "EUR"   # optional default
end
```

---

### Aggregate

`ES::Aggregate` reconstructs domain state from its event history. Each aggregate defines a `State` struct and a set of `apply` overloads — one per event type.

```crystal
class Order < ES::Aggregate
  @@type = "Order"

  struct State < ES::Aggregate::State
    property placed : Bool  = false
    property amount : Int64 = 0_i64
  end

  getter state : State

  def initialize(aggregate_id : UUID, @event_store : ES::EventStore)
    @state = State.new(aggregate_id)
    @state.set_type(@@type)
  end

  def apply(event : OrderPlaced)
    @state.placed = true
    @state.amount = event.body.as(OrderPlaced::Body).amount
    @state.increase_version(event.header.aggregate_version)
  end
end
```

---

### Decision

`ES::Decision(E)` is the pure result type returned by a decider.

```crystal
# Accepted — carries the events to append
ES::Decision(OrderEvent).accept([OrderPlaced.new(...)])

# Rejected — carries a reason; appends nothing
ES::Decision(OrderEvent).reject("Order already placed")

decision.accepted?  # Bool
decision.rejected?  # Bool
decision.events     # Array(E)  — empty on Rejected
decision.reason     # String    — raises on Accepted
decision == other   # value equality
```

---

### Decider

`ES::Decider(C, S, E)` is a module with three abstract methods and one concrete helper.

```crystal
class OrderDecider
  include ES::Decider(OrderCommand, Order::State, OrderEvent)

  def initial_state : Order::State
    Order::State.new(UUID.v7)
  end

  def evolve(state : Order::State, event : OrderEvent) : Order::State
    case event
    when OrderPlaced
      state.placed = true
      state.aggregate_version = event.header.aggregate_version
    end
    state
  end

  def decide(command : OrderCommand, state : Order::State) : ES::Decision(OrderEvent)
    case command
    when PlaceOrder
      return ES::Decision(OrderEvent).reject("already placed") if state.placed
      ES::Decision(OrderEvent).accept([
        OrderPlaced.new(aggregate_id: command.aggregate_id, ...),
      ])
    else
      ES::Decision(OrderEvent).reject("unknown command")
    end
  end
end
```

`fold(state, events)` is provided by the module and reduces `evolve` over an event slice:

```crystal
decider.fold(decider.initial_state, event_array)
```

`evolve` uses `state.set_version(event.header.aggregate_version)` (not `increase_version`)
so that `fold` works on **any starting state**, not just the canonical full stream from version 0.
This is the hinge for DCB.

---

### CommandHandler

`ES::CommandHandler(C, S, E)` is the generic impure shell that ties a decider to the event store.

```crystal
parse = ->(raw : ES::EventStore::Event) {
  h = ES::Event::Header.from_json(raw.header.to_json)
  event_handlers.event_class(h.event_handle).new(h, raw.body).as(OrderEvent)
}

handler = ES::CommandHandler(OrderCommand, Order::State, OrderEvent).new(
  OrderDecider.new, store, parse
)

outcome = handler.handle(aggregate_id, PlaceOrder.new(aggregate_id: aggregate_id))
```

Optimistic locking is provided by the store's `UNIQUE(aggregate_id, version)` constraint.
The decider embeds the correct next version (via `state.next_version`) into emitted event
headers; a concurrent writer that claimed the same version causes a DB constraint violation.

---

### DcbHandler (DCB-ready)

`ES::DcbHandler(C, S, E)` assembles state from a **tag-defined boundary** instead of a single
aggregate stream. The same decider is reused without modification — proving it is
boundary-agnostic.

```crystal
handler = ES::DcbHandler(OrderCommand, Order::State, OrderEvent).new(
  OrderDecider.new, tag_store, parse
)

boundary = ES::TagQuery.new(["account:#{account_id}", "order:#{order_id}"])
outcome  = handler.handle(command, boundary)
```

Requires the event store to implement `ES::DcbHandler::TagStore`
(`read_by_tags` + `append_if_unchanged`). Deferred until the tags/GIN-index store work is
scheduled — Phases 0–5 stand alone.

---

### Projection

`ES::Projection` maintains a read model by consuming events in order.

#### Projection DSL

`define_projection` generates the full projection class — table creation, column definitions,
index setup, and event handlers — from a concise block.

```crystal
define_projection("finance", "ledger") do
  column :id,             UUID,  primary_key: true
  column :transaction_id, UUID
  column :amount,         Int64

  index [:transaction_id], unique: true

  apply(TransactionInitiated) do |event|
    # insert into ledger table
  end
end
```

#### Schema Drift Detection

Every projection schema is **immutable**. When `setup_table` is called, a SHA-256 fingerprint
of the compiled schema is compared against the stored one. Divergence raises
`ES::Exception::SchemaDrift` before the projection can run.

---

### Event Bus

`ES::EventBus` fans out published events to registered projection handlers.

```crystal
bus = ES::EventBus(ES::Projection.class).new(store, event_handlers)
bus.subscribe(TransactionInitiated, Ledger)
bus.subscribe(TransactionAccepted,  Ledger)
bus.publish(event)
```

---

### Event Store

Two implementations are provided:

- **`ES::EventStoreAdapters::Postgres`** — JSONB rows, `UNIQUE(aggregate_id, version)`.
- **`ES::EventStoreAdapters::InMemory`** — for tests.

---

## Example: Financial Transaction

The [`financial-transaction`](./examples/financial-transaction) example demonstrates the
complete Command (data) + Decider + Handler flow.

### 1. Data-record command

```crystal
record ProcessTransaction, aggregate_id : UUID
alias TransactionCommand = ProcessTransaction
```

### 2. Event union

```crystal
alias TransactionEvent = Events::TransactionInitiated |
                         Events::TransactionAccepted  |
                         Events::TransactionRejected
```

### 3. Decider

```crystal
class TransactionDecider
  include ES::Decider(TransactionCommand, Aggregate::State, TransactionEvent)

  def initial_state : Aggregate::State
    s = Aggregate::State.new(UUID.v7)
    s.set_type("Transaction")
    s
  end

  def evolve(state : Aggregate::State, event : TransactionEvent) : Aggregate::State
    case event
    when Events::TransactionInitiated
      body = event.body.as(Events::TransactionInitiated::Body)
      state.amount = body.amount
      state.aggregate_version = event.header.aggregate_version
    when Events::TransactionAccepted
      state.accepted = true
      state.aggregate_version = event.header.aggregate_version
    when Events::TransactionRejected
      state.rejected = true
      state.aggregate_version = event.header.aggregate_version
    end
    state
  end

  def decide(command : TransactionCommand, state : Aggregate::State) : ES::Decision(TransactionEvent)
    case command
    when ProcessTransaction
      return ES::Decision(TransactionEvent).reject("Already settled") if state.accepted || state.rejected
      amount = state.amount.not_nil!
      if amount <= 1000
        ES::Decision(TransactionEvent).accept([
          Events::TransactionAccepted.new(
            aggregate_id: command.aggregate_id,
            aggregate_version: state.next_version,
            command_handler: "TransactionDecider",
          ).as(TransactionEvent),
        ])
      else
        ES::Decision(TransactionEvent).accept([
          Events::TransactionRejected.new(
            aggregate_id: command.aggregate_id,
            aggregate_version: state.next_version,
            command_handler: "TransactionDecider",
            reason: "Amount above threshold: #{amount}",
          ).as(TransactionEvent),
        ])
      end
    else
      ES::Decision(TransactionEvent).reject("Unknown command")
    end
  end
end
```

### 4. Wire everything together

```crystal
event_handlers = ES::EventHandlers.new
event_handlers.register(Events::TransactionInitiated)
event_handlers.register(Events::TransactionAccepted)
event_handlers.register(Events::TransactionRejected)

store   = ES::EventStoreAdapters::Postgres.new(db)
handler = build_transaction_handler(store, event_handlers)

# Initiate a transaction
init_event = Events::TransactionInitiated.new(
  creditor_account: creditor_id,
  debtor_account: debtor_id,
  amount: 500_i64,
)
store.append(init_event)

# Process it through the decider
outcome = handler.handle(
  init_event.header.aggregate_id,
  ProcessTransaction.new(aggregate_id: init_event.header.aggregate_id)
)

outcome.accepted? # => true
outcome.events    # => [Events::TransactionAccepted(...)]
```

---

## Changelog

### v0.7.0 (breaking)

- **Added** `ES::Decision(E)` — pure result type with value equality.
- **Added** `ES::Decider(C, S, E)` — pure decision + evolve + fold contract.
- **Added** `ES::CommandHandler(C, S, E)` — generic impure shell over the event store.
- **Added** `ES::DcbHandler(C, S, E)` — DCB-ready handler over a tag-defined boundary.
- **Added** `ES::Aggregate::State#set_version` — unrestricted version setter for the pure evolve path.
- **Removed** `ES::Command#call` abstract contract (breaking). `ES::Command` is retained as an empty base class during the transition window.
- **Bumped** shard version to `0.7.0`.

---

## Development

```bash
docker-compose up -d   # starts PostgreSQL
make test              # run the spec suite
```

---

## Contributing

1. Fork it (<https://github.com/tristanholl/crystal-es/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Tristan Holl](https://github.com/tristanholl) - creator and maintainer
