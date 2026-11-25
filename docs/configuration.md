# Configuration

`ES::Config` is a global singleton that wires dependencies together:

```crystal
ES::Config.event_handlers      = ES::EventHandlers.new
ES::Config.encryption          = ES::EncryptionKeyManager.new(key_store, application_key) # optional
ES::Config.tag_hasher          = ES::TagHasher.new(application_key)                        # optional
ES::Config.event_store         = ES::EventStoreAdapters::Postgres.new(db)
ES::Config.projection_database = db
ES::Config.event_bus           = ES::EventBus(ES::Reactor.class | ES::Projection.class).new
```

Set `encryption` and `tag_hasher` before creating the event store, which picks them up from `ES::Config`.

`encryption` is optional; leaving it unset behaves exactly as it did before payload
encryption existed. `tag_hasher` is optional too; it is only needed by events that
declare a `hashed: true` tag.

## Queue

> **Deprecated.** Deliver events with [Subscriptions](subscriptions.md) instead, see [Moving from the queue](subscriptions.md#moving-from-the-queue). The queue keeps working for now and will be removed in a later release.

`ES::Queue` is an outbox for events: its `setup` installs a trigger on `eventstore.events` that sends the header of every appended event to the queue, and a consumer reads the messages, fetches each event and publishes it on the event bus. That delivers each event to one process at a time, but gives no order between events, no position per handler, and runs every handler again when a message is redelivered. Two implementations:

- **`ES::QueueAdapters::Postgres`**: durable queue on the `pgmq` extension.
- **`ES::QueueAdapters::InMemory`**: for tests.
