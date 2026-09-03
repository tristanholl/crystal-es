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

Event bodies can be encrypted at rest, per event, under a key that can later be
destroyed to erase that data permanently.

Three pieces:

- **`ES::ApplicationEncryptionKeyManager`** holds the one application encryption key
  (the KEK). Passed in through the constructor — the library never reads it from the
  environment itself.
- **`ES::KeyStore`** stores data encryption keys (DEKs), each wrapped under the
  application key. `ES::KeyStoreAdapters::Postgres` and `::InMemory` are provided.
- **`ES::EncryptionKeyManager`** ties them together and is handed to the event store.

```crystal
application_key = ES::ApplicationEncryptionKeyManager.new(Base64.decode(ENV["APPLICATION_ENCRYPTION_KEY"]))
key_store       = ES::KeyStoreAdapters::Postgres.new(db)
key_store.setup

ES::Config.encryption  = ES::EncryptionKeyManager.new(key_store, application_key)
ES::Config.event_store = ES::EventStoreAdapters::Postgres.new(db)
```

Where the key comes from and how it's encoded (the example above assumes base64) is
up to the application; `ES::ApplicationEncryptionKeyManager` only ever sees the raw
key bytes.

#### Declaring an encrypted event

`encrypted: true` makes `encryption_key_id` a required constructor argument:

```crystal
define_event("customer", "customer_registered", encrypted: true) do
  attribute :name, String
  attribute :iban, String
end
```

The key is chosen when the event is constructed, not derived from it, so one
aggregate's events can sit under several keys — events carrying a customer's data can
be keyed by that customer even when the aggregate is an order:

```crystal
key_id = ES::Config.encryption.create_key

@event_store.append(CustomerRegistered.new(
  actor_id: actor, command_handler: "RegisterCustomer",
  encryption_key_id: key_id, name: name, iban: iban
))
```

#### Encryption is opt-in per application

Declaring `encrypted: true` on an event class has no effect on an application that
never configures `ES::Config.encryption` — encrypted and unencrypted event types can
coexist freely. Using an encrypted event without the matching configuration fails
loudly rather than writing something unencrypted or unreadable:

- **No encryption configured, appending an encrypted event** — raises
  `ES::Exception::InvalidState`.
- **No encryption configured, reading back an encrypted envelope** — raises
  `ES::Exception::DependencyUnavailable`.
- **Encryption configured, but the referenced key doesn't exist** (never created,
  destroyed, or from a different environment) — raises `ES::Exception::NotFound`.

#### Erasure

```crystal
# Everything about one aggregate
store.encryption_key_ids(aggregate_id).each { |id| ES::Config.encryption.destroy_key(id) }

# Or a key the application tracked itself
ES::Config.encryption.destroy_key(key_id)
```

The key table holds no reference to any business entity — references run one way
only, from an event header to a key. `encryption_key_ids` looks up the keys for a
single aggregate; a data subject spanning several aggregates is yours to map.
`destroy_key` deletes the row — deletion is the erasure, with no tombstone or
soft-delete flag.

#### Reading a stream after an erasure

Once a key is deleted, reading a body that names it raises `ES::Exception::NotFound`.
Aggregates and projections handle that differently:

- **`ES::Aggregate#hydrate`** propagates it — `fetch_events`/`fetch_event` raise
  straight through.
- **`ES::Projection#replay`/`#init`** do not. `EventStore#each_event` skips an event
  it can't decrypt and logs a warning before it reaches your `apply`. If `apply`
  itself hits a destroyed key indirectly (e.g. hydrating a related aggregate), the
  same `NotFound` is caught, logged, and skipped so replay continues.

This is unconditional — there is nothing to configure. Note that the library reuses
one `NotFound` for "missing row" and "key destroyed" alike, so a projection's `apply`
cannot raise `NotFound` for an unrelated reason without it also being treated as a
shredded key.

#### What this does and does not protect

Protected: event bodies at rest — dumps, backups, replicas, a DBA with `SELECT` — and
erasure by key destruction.

Not protected: the event header (stays plaintext, since it drives the flattened
view), application memory, logs, and projections — a projection built from an
encrypted event stores whatever it extracted in the clear, so purging or rebuilding
read models after an erasure is the application's job.

#### What is not offered

No key rotation, for either the application key or a data key, in this first
iteration. The application key must stay fixed for the lifetime of the store, the
same as any other irreplaceable secret.

#### Notes

Bodies are sealed with AES-256-CBC and an encrypt-then-MAC HMAC-SHA256 tag. An
encrypted body is stored as `{"iv": "<b64>", "ct": "<b64>", "tag": "<b64>"}` — the
header's `encryption_key_id` is what marks a body as encrypted, not a field on the
body itself, so encrypted and plaintext bodies coexist in one store with no migration
needed to turn encryption on for new events. Each ciphertext is bound to its own event
and its own key, so an envelope can't be moved to another row or opened under a
header naming a different key.

---

### Configuration

`ES::Config` is a global singleton that wires dependencies together:

```crystal
ES::Config.configure do |c|
  c.event_store = ES::Adapters::EventStores::Postgres.new(db)
  c.queue       = ES::Adapters::Queues::Postgres.new(db)
  c.event_bus   = ES::EventBus(ES::Reactor.class | ES::Projection.class).new
  c.encryption  = ES::EncryptionKeyManager.new(key_store, application_key) # optional
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

### Coding standards

Two tools guard the code style, and both run in CI on every push and pull
request:

- `crystal tool format`, the formatter that ships with the compiler.
- [Ameba](https://github.com/crystal-ameba/ameba), a static analyser for
  Crystal that catches code smells, dead assignments and constructs that work
  but read badly.

```bash
make lint          # formatter check + Ameba, the same pair CI runs
make lint-format   # formatter check only
make lint-ameba    # Ameba only
make lint-fix      # rewrite files: format, then auto-correct what Ameba can
```

Ameba is a development dependency, so `shards install` pulls it in. The binary
is compiled into `bin/ameba` by `shards build ameba` and is baked into the dev
image, which is why `make lint` starts instantly rather than compiling the
linter first.

Rules are configured in [`.ameba.yml`](.ameba.yml). It runs Ameba's defaults
apart from three rules that are switched off, each with the reason next to it in
the file: two of them would rename accessors that are part of this shard's
public API, and the third would rewrite every migration's SQL literal as a
heredoc. A single line can be exempted in place instead of globally:

```crystal
# ameba:disable Naming/BlockParameterName
items.each { |x| puts x }
```

---

## Contributing

1. Fork it (<https://github.com/tristanholl/crystal-es/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Run `make test` and `make lint` — CI runs both and will reject a red branch
5. Push to the branch (`git push origin my-new-feature`)
6. Create a new Pull Request

## Contributors

- [Tristan Holl](https://github.com/tristanholl) - creator and maintainer
