# Payload encryption

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

## Declaring an encrypted event

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

## Encryption is opt-in per application

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

## Erasure

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

## Reading a stream after an erasure

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

## What this does and does not protect

Protected: event bodies at rest — dumps, backups, replicas, a DBA with `SELECT` — and
erasure by key destruction.

Not protected: the event header (stays plaintext, since it drives the flattened
view; this includes its tags, see [Tags](events.md#tags)), application memory, logs, and projections — a projection built from an
encrypted event stores whatever it extracted in the clear, so purging or rebuilding
read models after an erasure is the application's job.

## What is not offered

No key rotation, for either the application key or a data key, in this first
iteration. The application key must stay fixed for the lifetime of the store, the
same as any other irreplaceable secret.

## Notes

Bodies are sealed with AES-256-CBC and an encrypt-then-MAC HMAC-SHA256 tag. An
encrypted body is stored as `{"iv": "<b64>", "ct": "<b64>", "tag": "<b64>"}` — the
header's `encryption_key_id` is what marks a body as encrypted, not a field on the
body itself, so encrypted and plaintext bodies coexist in one store with no migration
needed to turn encryption on for new events. Each ciphertext is bound to its own event
and its own key, so an envelope can't be moved to another row or opened under a
header naming a different key.
