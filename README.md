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

`crystal-es` is an event sourcing foundation for Crystal applications. It is optimized for PostgreSQL as event store and projection database, and was originally extracted from an open-source core-banking project.

The library provides:
- **Aggregates** — reconstruct domain state by replaying events
- **Commands** — pure data records expressing an intent to change state
- **Command Handlers** — enforce business logic and emit events
- **Reactors** — consume events off the bus and trigger the next command
- **Events** — immutable facts with a type-safe DSL
- **Projections** — read models built from event streams, with a schema DSL and schema drift detection
- **Event Bus** — fan-out published events to reactors and projections
- **Subscriptions** — deliver events to reactors and projections exactly once and in order, across any number of application instances, on Postgres alone (see [Subscriptions](docs/subscriptions.md))
- **Dynamic consistency boundaries** — tag events, read them by type and tag, and append on the condition that none of the tags a decision depended on moved (see [Tags](docs/events.md#tags), [Querying by tag](docs/consistency.md#querying-by-tag), [Tag versions and conditional appends](docs/consistency.md#tag-versions-and-conditional-appends) and [Decision projections](docs/consistency.md#decision-projections))
- **Adapters** — PostgreSQL and in-memory implementations for event stores, key stores and subscription stores

A complete working example lives in [`./examples/financial-transaction`](./examples/financial-transaction). [`./examples/course-subscription`](./examples/course-subscription) shows dynamic consistency boundaries: course capacity and a per-student limit enforced together, unique hashed emails, and erasure.

See the [changelog](./CHANGELOG.md) for upgrade notes between versions.

## Documentation

| Topic | Covers |
|---|---|
| [Events](docs/events.md) | `ES::Event`, the `define_event` DSL, tags and hashed tags |
| [Aggregates, commands and command handlers](docs/aggregates-and-commands.md) | Rebuilding state from events, expressing intent, enforcing invariants |
| [Reactors and the event bus](docs/reactors-and-event-bus.md) | Turning events into the next command, routing events to handlers |
| [Projections](docs/projections.md) | The `define_projection` DSL, indexes, schema drift detection |
| [Subscriptions](docs/subscriptions.md) | Exactly-once, in-order delivery across application instances, operations, limits |
| [Event store](docs/event-store.md) | Adapters, transactions, reading the store as a log |
| [Dynamic consistency boundaries](docs/consistency.md) | Querying by tag, tag versions, conditional appends, decision projections |
| [Payload encryption](docs/encryption.md) | Encrypted bodies, erasure by key destruction, what is and isn't protected |
| [Configuration](docs/configuration.md) | `ES::Config`, and the deprecated queue |
| [Recommended project structure](docs/recommended-project-structure.md) | Organizing an application by domain: folders, naming, boundaries between domains, wiring, specs |

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

The ledger is declared `atomic: true` and writes through `write`, so each batch of events commits together with the projection's position and every event is booked exactly once (see [Subscriptions](docs/subscriptions.md#projections)).

```crystal
# projections/ledger.cr
class Ledger < ES::Projection
  include ES::ProjectionDSL

  define_projection "finance.ledger", atomic: true do
    column :id,               UUID,  primary_key: true
    column :creditor_account, UUID
    column :debtor_account,   UUID
    column :amount,           Int64
    column :accepted_at,      Time,  null: true
    column :rejected_at,      Time,  null: true
  end

  apply(TransactionInitiated) do
    write do |connection|
      connection.exec %(INSERT INTO "finance"."ledger" (id, creditor_account, debtor_account, amount) VALUES ($1, $2, $3, $4)),
        aggregate_id, body.creditor_account, body.debtor_account, body.amount
    end
  end

  apply(TransactionAccepted) do
    write do |connection|
      connection.exec %(UPDATE "finance"."ledger" SET accepted_at = $1 WHERE id = $2), created_at, aggregate_id
    end
  end

  apply(TransactionRejected) do
    write do |connection|
      connection.exec %(UPDATE "finance"."ledger" SET rejected_at = $1 WHERE id = $2), created_at, aggregate_id
    end
  end
end
```

### 6. Wire Everything Together

```crystal
require "crystal-es"
require "db"
require "pg"

db = DB.open(ENV["DATABASE_URL"])

ES::Config.event_handlers = ES::EventHandlers.new
ES::Config.event_handlers.register(TransactionInitiated)
ES::Config.event_handlers.register(TransactionAccepted)
ES::Config.event_handlers.register(TransactionRejected)

ES::Config.event_store = ES::EventStoreAdapters::Postgres.new(db)
ES::Config.event_store.setup

ES::Config.projection_database = db
Ledger.new.setup

# The routing: which reactors and projections receive which events
ES::Config.event_bus = ES::EventBus(ES::Reactor.class | ES::Projection.class).new
bus = ES::Config.event_bus
bus.subscribe(TransactionInitiated, [OnTransactionInitiated, Ledger])
bus.subscribe(TransactionAccepted, Ledger)
bus.subscribe(TransactionRejected, Ledger)

# Deliver the events, on every instance of the application
subscriptions = ES::Subscriptions.new
subscriptions.start
at_exit { subscriptions.stop }

# Initiate a transaction. The reactor processes it, and the ledger books it.
ES::Config.event_store.append(TransactionInitiated.new(
  actor_id: nil,
  command_handler: "example",
  amount: 5_000_i64,
  creditor_account: UUID.random,
  debtor_account: UUID.random
))
```

---

## Development

See [CONTRIBUTING.md](./CONTRIBUTING.md) for the development environment, coding standards and how to submit a change.

## Contributors

- [Tristan Holl](https://github.com/tristanholl) - creator and maintainer
