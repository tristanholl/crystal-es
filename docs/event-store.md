# Event store

`ES::EventStore` is the persistence layer for events. Two implementations are provided:

- **`ES::Adapters::EventStores::Postgres`** — stores events as JSONB rows with unique `(aggregate_id, version)` constraints. Provides a flattened view for stream queries and cursor-based pagination for batch replay.
- **`ES::Adapters::EventStores::InMemory`** — lightweight implementation for tests.

## Transactions

`transaction` runs a block in one transaction and yields an event store bound to it. Everything appended through that store commits when the block returns, or nothing does if it raises. Reads through it see its own appends:

```crystal
event_store.transaction do |store|
  ReserveStockHandler.new(event_store: store).handle(reserve)
  ChargePaymentHandler.new(event_store: store).handle(charge)
end
```

On Postgres, each append runs in a savepoint, so a `Conflict` can be rescued inside the block and the transaction goes on. Only work done through the yielded store joins the transaction. Subscriptions run every reactor this way.

## Reading the store as a log

`read_log(after, limit, handles: nil, partition: nil)` reads events in the order of the transactions that appended them, up to `log_head`, and is the one read that is safe to resume from a saved position (see [How it works](subscriptions.md#how-it-works)). Each event carries its `log_position`, and the page's `last_position` is how far the read got, past events the filters left out:

```crystal
position = ES::EventStore::LogPosition::ZERO
page = event_store.read_log(position, limit: 100, handles: [OrderPlaced.handle])
page.events.each { |event| handle(event) }
position = page.last_position
```
