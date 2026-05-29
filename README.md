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
- **Aggregates** — reconstruct domain state by replaying events
- **Commands** — enforce business logic and emit events
- **Events** — immutable facts with a type-safe DSL
- **Projections** — read models built from event streams, with a schema DSL
- **Event Bus** — fan-out published events to registered handlers
- **Adapters** — PostgreSQL and in-memory implementations for event stores and queues

A complete working example lives in [`./examples/financial-transaction`](./examples/financial-transaction).

---

## Components

### Event

`ES::Event` is the base class for all domain events. Each event carries a **Header** (metadata) and a **Body** (event-specific payload).

```crystal
class OrderPlaced < ES::Event
  aggregate_type "order"
  event_handle "order_placed"

  class Body
    include JSON::Serializable
    getter order_id : UUID
    getter amount : Int64

    def initialize(@order_id, @amount); end
  end
end
```

#### Event DSL

The `define_event` macro removes the boilerplate. It generates the full event class, the `Body` struct with JSON serialization, and registers the handle automatically.

```crystal
define_event("order", "order_placed") do
  attribute :order_id, UUID
  attribute :amount, Int64
  attribute :currency, String, "EUR"   # optional default
end
```

`attribute(name, type, default?)` — declare a typed field on the event body. A default value makes the field optional at construction time.

---

### Aggregate

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

---

### Command

`ES::Command` encapsulates a single business operation. It hydrates the relevant aggregate, evaluates business rules, and appends new events.

```crystal
class PlaceOrder < ES::Command
  def call
    order = Order.hydrate(@aggregate_id, event_store)
    raise ES::InvalidState.new("already placed") if order.state.placed

    append OrderPlaced.new(
      aggregate_id: @aggregate_id,
      body: OrderPlaced::Body.new(order_id: @aggregate_id, amount: @amount)
    )
  end
end
```

---

### Projection

`ES::Projection` maintains a read model by consuming events in order. It can be replayed from scratch at any time.

#### Projection DSL

`define_projection` generates the full projection class — table creation, column definitions, index setup, and event handlers — from a concise block.

```crystal
define_projection("ledger", "postings") do
  column :id,         UUID,   primary_key: true
  column :account_id, UUID
  column :amount,     Int64
  column :posted_at,  Time

  index [:account_id]
  index [:id], unique: true

  apply(OrderPlaced) do |event|
    # insert into postings table
  end
end
```

**`column(name, type, **options)`** maps Crystal types to PostgreSQL column types:

| Crystal type | PostgreSQL type |
|---|---|
| `String` | `TEXT` |
| `Int64` | `BIGINT` |
| `UUID` | `UUID` |
| `Time` | `TIMESTAMPTZ` |
| `Bool` | `BOOLEAN` |

**`index(columns, unique: false, name: nil)`** — add an index to the projection table.

**`apply(EventClass) { |event| ... }`** — handle an event to update the read model.

---

### Event Bus

`ES::EventBus` fans out published events to all registered handlers (commands and projections).

```crystal
bus = ES::EventBus(ES::Command | ES::Projection).new
bus.subscribe(OrderPlaced, PlaceOrderHandler)
bus.subscribe(OrderPlaced, OrdersProjection)

bus.publish(event)
```

---

### Event Store

`ES::EventStore` is the persistence layer for events. Two implementations are provided:

- **`ES::Adapters::EventStores::Postgres`** — stores events as JSONB rows with unique `(aggregate_id, version)` constraints. Provides a flattened view for stream queries and cursor-based pagination for batch replay.
- **`ES::Adapters::EventStores::InMemory`** — lightweight implementation for tests.

---

### Queue

`ES::Queue` provides asynchronous command processing. Two implementations:

- **`ES::Adapters::Queues::Postgres`** — durable queue backed by a PostgreSQL table.
- **`ES::Adapters::Queues::InMemory`** — for tests and simple scenarios.

---

### Configuration

`ES::Config` is a global singleton that wires dependencies together:

```crystal
ES::Config.configure do |c|
  c.event_store = ES::Adapters::EventStores::Postgres.new(db)
  c.queue       = ES::Adapters::Queues::Postgres.new(db)
  c.event_bus   = ES::EventBus(ES::Command | ES::Projection).new
end
```

---

## Project Structure

For larger projects, the following vertical-slice layout works well:

```
src/
  domains/
    orders/
      aggregates/
        order.cr
      commands/
        place_order.cr
        cancel_order.cr
      events/
        order_placed.cr
        order_cancelled.cr
      projections/
        orders_list.cr
    payments/
      ...
  shared/
    ...
```

---

## Example: Financial Transaction

Below is an abridged version of the [`financial-transaction`](./examples/financial-transaction) example that shows the full event sourcing flow.

### 1. Define Events

```crystal
# events/transaction_initiated.cr
define_event("transaction", "transaction_initiated") do
  attribute :amount,           Int64
  attribute :creditor_account, UUID
  attribute :debtor_account,   UUID
end

# events/transaction_accepted.cr
define_event("transaction", "transaction_accepted") do
end

# events/transaction_rejected.cr
define_event("transaction", "transaction_rejected") do
end
```

### 2. Define the Aggregate

```crystal
# aggregates/transaction.cr
class Transaction < ES::Aggregate
  struct State
    property amount           : Int64 = 0_i64
    property creditor_account : UUID? = nil
    property debtor_account   : UUID? = nil
    property accepted         : Bool  = false
    property rejected         : Bool  = false
  end

  def apply(event : TransactionInitiated)
    @state.amount           = event.body.amount
    @state.creditor_account = event.body.creditor_account
    @state.debtor_account   = event.body.debtor_account
  end

  def apply(event : TransactionAccepted)
    @state.accepted = true
  end

  def apply(event : TransactionRejected)
    @state.rejected = true
  end
end
```

### 3. Define a Command

```crystal
# commands/process_transaction.cr
class ProcessTransaction < ES::Command
  LIMIT = 10_000_i64

  def call
    tx = Transaction.hydrate(@aggregate_id, event_store)

    if tx.state.amount <= LIMIT
      append TransactionAccepted.new(aggregate_id: @aggregate_id)
    else
      append TransactionRejected.new(aggregate_id: @aggregate_id)
    end
  end
end
```

### 4. Define a Projection

```crystal
# projections/ledger.cr
define_projection("finance", "ledger") do
  column :id,               UUID,   primary_key: true
  column :transaction_id,   UUID
  column :creditor_account, UUID
  column :debtor_account,   UUID
  column :amount,           Int64
  column :accepted_at,      Time,   nullable: true
  column :rejected_at,      Time,   nullable: true

  index [:transaction_id], unique: true

  apply(TransactionInitiated) do |event|
    db.exec(
      "INSERT INTO finance.ledger (id, transaction_id, creditor_account, debtor_account, amount)
       VALUES ($1, $2, $3, $4, $5)",
      UUID.random, event.header.aggregate_id,
      event.body.creditor_account, event.body.debtor_account, event.body.amount
    )
  end

  apply(TransactionAccepted) do |event|
    db.exec(
      "UPDATE finance.ledger SET accepted_at = $1 WHERE transaction_id = $2",
      Time.utc, event.header.aggregate_id
    )
  end

  apply(TransactionRejected) do |event|
    db.exec(
      "UPDATE finance.ledger SET rejected_at = $1 WHERE transaction_id = $2",
      Time.utc, event.header.aggregate_id
    )
  end
end
```

### 5. Wire Everything Together

```crystal
require "crystal-es"
require "db"
require "pg"

db = DB.open(ENV["DATABASE_URL"])

ES::Config.configure do |c|
  c.event_store    = ES::Adapters::EventStores::Postgres.new(db)
  c.queue          = ES::Adapters::Queues::Postgres.new(db)
  c.event_bus      = ES::EventBus(ES::Command | ES::Projection).new
  c.event_handlers = ES::EventHandlers.new
end

# Register event types for deserialization
ES::Config.event_handlers.register(TransactionInitiated)
ES::Config.event_handlers.register(TransactionAccepted)
ES::Config.event_handlers.register(TransactionRejected)

# Subscribe handlers to events
bus = ES::Config.event_bus
bus.subscribe(TransactionInitiated, ProcessTransaction)
bus.subscribe(TransactionInitiated, Ledger)
bus.subscribe(TransactionAccepted,  Ledger)
bus.subscribe(TransactionRejected,  Ledger)

# Initiate a transaction
aggregate_id = UUID.random
event = TransactionInitiated.new(
  aggregate_id: aggregate_id,
  body: TransactionInitiated::Body.new(
    amount: 5_000_i64,
    creditor_account: UUID.random,
    debtor_account: UUID.random
  )
)

ES::Config.event_store.append(event)
bus.publish(event)
```

---

## Development

Start the development environment with Docker:

```bash
docker-compose up -d   # starts PostgreSQL
make test              # run the spec suite
```

---

## Contributing

1. Fork it (<https://github.com/tristanholl/crystal-es/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Tristan Holl](https://github.com/tristanholl) - creator and maintainer
