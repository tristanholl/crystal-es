# Configuration

`ES::Config` is a global singleton that wires dependencies together:

```crystal
ES::Config.configure do |config|
  config.event_handlers      = ES::EventHandlers.new
  config.encryption          = ES::EncryptionKeyManager.new(key_store, application_key) # optional
  config.tag_hasher          = ES::TagHasher.new(application_key)                        # optional
  config.event_store         = ES::EventStoreAdapters::Postgres.new(db)
  config.projection_database = db
  config.event_bus           = ES::EventBus(ES::Reactor.class | ES::Projection.class).new
end
```

The block only groups the setters, and each one works on its own too (`ES::Config.event_store = ...`). Order matters either way, because components read `ES::Config` when they're created: set `encryption` and `tag_hasher` before creating the event store, and `event_handlers` and `event_store` before creating the event bus.

`encryption` is optional; leaving it unset behaves exactly as it did before payload
encryption existed. `tag_hasher` is optional too; it is only needed by events that
declare a `hashed: true` tag.

## Queue

> **Deprecated.** Deliver events with [Subscriptions](subscriptions.md) instead, see [Moving from the queue](subscriptions.md#moving-from-the-queue). The queue keeps working for now and will be removed in a later release.

`ES::Queue` is an outbox for events: its `setup` installs a trigger on `eventstore.events` that sends the header of every appended event to the queue, and a consumer reads the messages, fetches each event and publishes it on the event bus. That delivers each event to one process at a time, but gives no order between events, no position per handler, and runs every handler again when a message is redelivered. Two implementations:

- **`ES::QueueAdapters::Postgres`**: durable queue on the `pgmq` extension.
- **`ES::QueueAdapters::InMemory`**: for tests.
