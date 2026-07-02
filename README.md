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
- **Projections** — read models built from event streams, with a schema DSL and schema drift detection
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

### Dynamic Consistency Boundaries (DCB)

Classic event sourcing enforces consistency per single aggregate. With **dynamic consistency boundaries** a command can build its decision model from *several* sequences — aggregates and/or **tags** — and atomically append events **conditioned on none of those sequences having advanced** since they were read.

The consistency condition is based purely on per-sequence version numbers (the same optimistic versioning aggregates already use), never on a global sequence. The global `BIGSERIAL id` of the Postgres store remains a projection-replay ordering concern only.

**Sequences.** Every event belongs to one or more sequences, each with its own monotonically increasing version:
- its primary aggregate (`aggregate_id` / `aggregate_version`), as before
- any number of extra **tags** via the new `tags` header field (`Hash(String, Int32)`), e.g. `{"course:<uuid>" => 3}`

**Conditional append.** `EventStore#append(events, condition)` atomically appends a batch and raises `ES::Exception::Conflict` if any sequence named in the `ES::AppendCondition` advanced past its expected version — including sequences the batch does not write to (read-only boundary members). In Postgres this is enforced with per-sequence advisory locks and an `event_tags` table with a `UNIQUE(tag, tag_version)` backstop; the in-memory store enforces identical semantics.

**`ES::Boundary`** is the command-layer API: load the sequences the decision depends on (capturing their versions), stage events, and commit atomically.

```crystal
class Commands::SubscribeStudent < ES::Command
  def call
    # Boundary member 1: the student aggregate
    student = boundary.load(Student.new(@aggregate_id))

    # Boundary member 2: the course tag sequence (the course is not an aggregate)
    course_tag = "course:#{@course_id}"
    subscriptions = 0
    boundary.load(course_tag) do |event|
      subscriptions += 1 if event.header["event_handle"] == "student_subscribed"
    end

    raise ES::Exception::InvalidState.new("course full") if subscriptions >= 10
    raise ES::Exception::InvalidState.new("too many courses") if student.state.course_count >= 5

    boundary.stage(Events::StudentSubscribed.new(
      aggregate_id: @aggregate_id,
      aggregate_version: boundary.next_version(student),
      tags: {course_tag => boundary.next_version(course_tag)},
      course_id: @course_id,
      # ...
    ))

    # Atomic: raises ES::Exception::Conflict if the student OR the course
    # sequence advanced since it was loaded
    boundary.commit
  end
end
```

If two such commands race, the loser gets an `ES::Exception::Conflict` even though the two events live under different primary aggregates — the shared course tag serializes them. A sequence can also be enlisted read-only (assert it did not change without writing to it) via `boundary.load(tag) { ... }` or `boundary.track(key, version)` with no staged event carrying that tag.

A complete runnable example lives in [`./examples/course-subscription`](./examples/course-subscription) (`crystal run examples/course-subscription/example.cr` — uses the in-memory store, no infrastructure needed).

> **Note on Postgres pooling:** the conditional append relies on transaction-scoped advisory locks; all statements run on a single connection inside one transaction. When using a pooling proxy, transaction pooling is the minimum requirement — statement pooling breaks the lock semantics.

> **Migration:** `EventStore#setup` is idempotent; re-running it on an existing store creates the `event_tags` table and backfills the primary-aggregate memberships of existing events.

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

#### Schema Drift Detection

Every projection schema is **immutable**. When `setup_table` is called, the library computes a SHA-256 fingerprint of the compiled schema (columns, types, nullability, defaults, indexes) and compares it against the fingerprint stored in `_crystal_es_projection_metadata`. If they diverge, a `ES::Exception::SchemaDrift` exception is raised before the projection can run.

**Breaking changes** (raise `SchemaDrift`):
- Column added, removed, or reordered
- Column type or Crystal type changed
- Nullability or default value changed
- Primary key changed

**Non-breaking changes** (logged as a warning, metadata updated):
- Index added, removed, or modified

The error message tells you exactly what changed:

```
Schema drift detected for 'Ledger' (table: finance.ledger).
Stored fingerprint:   abc123...
Compiled fingerprint: def456...
Changes:
  breaking column_type_changed: column "amount" type changed from TEXT to BIGINT
Projection schemas are immutable. Define a new projection class with a new table
name, populate it from the event store, then rewire the application to the new projection.
```

To evolve a projection, create a new projection class targeting a new table name, replay the event store into it, then cut the application over. There is no in-place migration path — this is by design.

You can also inspect drift status without triggering an exception:

```crystal
status = Ledger.drift_status(db)
# => ES::ProjectionMeta::DriftStatus with fingerprints and list of SchemaChange objects
```

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
