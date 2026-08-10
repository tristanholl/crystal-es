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
- **Commands** — pure data records expressing an intent to change state
- **Command Handlers** — enforce business logic and emit events
- **Reactors** — consume events off the bus and trigger the next command
- **Events** — immutable facts with a type-safe DSL
- **Projections** — read models built from event streams, with a schema DSL and schema drift detection
- **Event Bus** — fan-out published events to reactors and projections
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

`ES::Command` is a pure data record expressing an intent to change state. Following strict event sourcing, it carries only the target aggregate and its payload — it has no behavior.

```crystal
struct PlaceOrder < ES::Command
  getter amount : Int64

  def initialize(@aggregate_id : UUID, @amount : Int64)
  end
end
```

---

### Command Handler

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

---

### Reactor

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

---

### Projection

`ES::Projection` maintains a read model by consuming events in order. It can be replayed from scratch at any time.

#### Projection DSL

`define_projection` generates the full projection class — table creation, column definitions, index setup, and event handlers — from a concise block.

```crystal
class Postings < ES::Projection
  include ES::ProjectionDSL

  define_projection "ledger.postings" do
    column :id,         UUID, primary_key: true
    column :account_id, UUID
    column :amount,     Int64
    column :posted_at,  Time

    index [:account_id]
    index [:id], unique: true
  end

  # Event handlers are declared on the class, not inside the block —
  # `define_projection` reads only `column` and `index` declarations.
  apply(OrderPlaced) do
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

**`apply(EventClass) { ... }`** — handle an event to update the read model. Declared on the class body, alongside `define_projection` rather than inside it. Within the block, `header`, `aggregate_id`, `aggregate_version`, `created_at` and `body` are pre-bound. A plain `def apply(event : EventClass)` works identically.

A projection consumes only the events it declares an `apply` for; `EventBus#subscribe` rejects a subscription to any other event. To consume everything, override the catch-all `apply(event : ES::Event)` instead.

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

### Payload Encryption

Event bodies can be encrypted at rest so that destroying one key erases the data
under it — an event store is immutable, so a key you can destroy is the only way to
answer an erasure request. Confidentiality at rest comes along for free.

Three pieces:

- **`ES::ApplicationKeyRing`** holds the application encryption keys (KEKs), read from
  the environment. These are the only secrets you manage.
- **`ES::KeyStore`** stores data encryption keys (DEKs), each wrapped under a KEK.
  `ES::KeyStoreAdapters::Postgres` and `::InMemory` are provided. Deliberately not
  event sourced — the whole point is that a row can be destroyed.
- **`ES::Encryption`** ties them together and is handed to the event store.

```crystal
key_ring   = ES::ApplicationKeyRing.from_env
key_store  = ES::KeyStoreAdapters::Postgres.new(db)
key_store.setup

ES::Config.encryption  = ES::Encryption.new(key_store, key_ring)
ES::Config.event_store = ES::EventStoreAdapters::Postgres.new(db)
```

```
ES_APPLICATION_KEYS="v1:<base64 32 bytes>,v2:<base64 32 bytes>"
ES_APPLICATION_KEY_CURRENT="v2"
```

#### Declaring an encrypted event

`encrypted: true` makes `encryption_key_id` a **required** constructor argument, so an
event carrying protected data cannot be built without naming the key it will be sealed
under:

```crystal
define_event("customer", "customer_registered", encrypted: true) do
  attribute :name, String
  attribute :iban, String
end
```

The key is chosen when the event is constructed, not derived from it. That is what lets
one aggregate's events sit under several keys — events carrying a customer's data can be
keyed by that customer even when the aggregate is an order:

```crystal
key_id = ES::Config.encryption.create_key

@event_store.append(CustomerRegistered.new(
  actor_id: actor, command_handler: "RegisterCustomer",
  encryption_key_id: key_id, name: name, iban: iban
))
```

Appending a declared-encrypted event to a store with no encryption configured raises,
rather than quietly writing plaintext.

#### Erasure

```crystal
# Everything about one aggregate
store.encryption_key_ids(aggregate_id).each { |id| ES::Config.encryption.destroy_key(id) }

# Or a key the application tracked itself
ES::Config.encryption.destroy_key(key_id)
```

The key table holds **no reference to any business entity** — references run one way
only, from an event header to a key, so domain identifiers never accumulate next to the
keys. The reverse lookup is `encryption_key_ids` for a single aggregate; a data subject
spanning several aggregates is yours to map.

Destroying a key nulls its material and leaves a tombstone row, which is what lets a
reader tell a deliberate erasure from a key that was never there.

#### Reading a shredded stream

A destroyed key is reported rather than raised on, because the right response differs by
caller:

| Caller | Behaviour |
|---|---|
| `ES::Aggregate#hydrate` | raises `ES::Exception::KeyDestroyed` |
| `ES::Aggregate#hydrate` with `skip_shredded_events: true` | bumps the version, rebuilds from what is left |
| `ES::Projection#replay` / `#init` | skips the event, so read models stay rebuildable after an erasure |

`ES::EventStore::Event#shredded?` exposes this if you read the store directly.

#### What this does and does not protect

Protected: event bodies at rest — dumps, backups, replicas, a DBA with `SELECT` — and
erasure by key destruction.

Not protected: the event *header* (it is indexed and drives the flattened view, so it
stays plaintext), application memory, logs, and **projections**. A projection built from
an encrypted event stores whatever it extracted in the clear; encryption stops at the
event store, and purging or rebuilding read models after an erasure is the application's
job.

#### Rotation, and what is not offered

Rotating the application key re-wraps the data keys and touches no events:

```crystal
ES::Config.encryption.rewrap_all
```

Rotating a *data* key is deliberately absent — it would mean re-encrypting stored bodies,
which is a rewrite of the event store. Since the key id lives per event in the header, new
events simply start using a new key.

#### Notes

Bodies are sealed with AES-256-CBC and an encrypt-then-MAC HMAC-SHA256 tag. AES-GCM would
be the obvious choice, but Crystal's `OpenSSL::Cipher` only gained `gcm_tag` after 1.17 and
released versions bind no way to reach it, so GCM would require reopening a stdlib class.

An encrypted body is stored as a JSON envelope tagged `__es`. Encrypted and plaintext
bodies coexist in one store, so encryption can be switched on for new events with no
migration and no backfill of history. Each ciphertext is bound to its own event, so an
envelope cannot be moved to another row even by someone holding the key.

---

### Configuration

`ES::Config` is a global singleton that wires dependencies together:

```crystal
ES::Config.configure do |c|
  c.event_store = ES::Adapters::EventStores::Postgres.new(db)
  c.queue       = ES::Adapters::Queues::Postgres.new(db)
  c.event_bus   = ES::EventBus(ES::Reactor.class | ES::Projection.class).new
  c.encryption  = ES::Encryption.new(key_store, key_ring) # optional
end
```

`encryption` is optional; leaving it unset behaves exactly as it did before payload
encryption existed.

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

### 3. Define a Command and its Handler

```crystal
# commands/process_transaction.cr
struct ProcessTransaction < ES::Command
end

class ProcessTransactionHandler < ES::CommandHandler(ProcessTransaction)
  LIMIT = 10_000_i64

  def handle(command : ProcessTransaction)
    tx = Transaction.new(command.aggregate_id, event_store: @event_store)
    tx.hydrate

    if tx.state.amount <= LIMIT
      @event_store.append(TransactionAccepted.new(aggregate_id: command.aggregate_id))
    else
      @event_store.append(TransactionRejected.new(aggregate_id: command.aggregate_id))
    end
  end
end
```

### 4. Define a Reactor

The reactor turns an incoming event into the next command. This is where the workflow lives — `TransactionInitiated` triggers `ProcessTransaction`.

```crystal
# reactors/on_transaction_initiated.cr
class OnTransactionInitiated < ES::Reactor
  def call(event : TransactionInitiated)
    ProcessTransactionHandler.new(event_store: @event_store).handle(
      ProcessTransaction.new(aggregate_id: event.header.aggregate_id)
    )
  end
end
```

### 5. Define a Projection

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

### 6. Wire Everything Together

```crystal
require "crystal-es"
require "db"
require "pg"

db = DB.open(ENV["DATABASE_URL"])

ES::Config.configure do |c|
  c.event_store    = ES::Adapters::EventStores::Postgres.new(db)
  c.queue          = ES::Adapters::Queues::Postgres.new(db)
  c.event_bus      = ES::EventBus(ES::Reactor.class | ES::Projection.class).new
  c.event_handlers = ES::EventHandlers.new
end

# Register event types for deserialization
ES::Config.event_handlers.register(TransactionInitiated)
ES::Config.event_handlers.register(TransactionAccepted)
ES::Config.event_handlers.register(TransactionRejected)

# Subscribe reactors and projections to events
bus = ES::Config.event_bus
bus.subscribe(TransactionInitiated, OnTransactionInitiated)
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
