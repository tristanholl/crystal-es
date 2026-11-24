# Configuration

`ES::Config` is a global singleton that wires dependencies together:

```crystal
ES::Config.configure do |c|
  c.event_store = ES::Adapters::EventStores::Postgres.new(db)
  c.queue       = ES::Adapters::Queues::Postgres.new(db)
  c.event_bus   = ES::EventBus(ES::Reactor.class | ES::Projection.class).new
  c.encryption  = ES::EncryptionKeyManager.new(key_store, application_key) # optional
  c.tag_hasher  = ES::TagHasher.new(application_key)                        # optional
end
```

`encryption` is optional; leaving it unset behaves exactly as it did before payload
encryption existed. `tag_hasher` is optional too; it is only needed by events that
declare a `hashed: true` tag.

## Queue

`ES::Queue` provides asynchronous command processing. For delivering events to reactors and projections across several instances, use [Subscriptions](subscriptions.md) instead. Two implementations:

- **`ES::Adapters::Queues::Postgres`** — durable queue backed by a PostgreSQL table.
- **`ES::Adapters::Queues::InMemory`** — for tests and simple scenarios.
