# Changelog

## 0.11.0

### Added

Dynamic consistency boundaries: a consistency boundary can be drawn around the events carrying a set of tags, instead of around one aggregate's stream. Aggregates keep working unchanged.

- **Tags.** `tag :attribute` inside `define_event` puts an attribute's value on the event as a tag. `hashed: true` stores an HMAC of the value instead. The key is derived from the application encryption key, and hashing is switched on with `ES::Config.tag_hasher = ES::TagHasher.new(application_key)`. A key declared hashed in one event and plain in another produces a compile-time warning.
- **Query reads.** `EventStore#read(ES::Query, after:, limit:)` returns the events of any of an item's types that carry all of its tags, in append order and with their `position`. An event whose encryption key was destroyed comes back with its header but no body, flagged `body_erased?`.
- **Conditional appends.** `EventStore#append(events, ES::AppendCondition)` appends a batch atomically, and only if no event matching the condition's query was appended after a position. Otherwise it raises `ES::Exception::Conflict`.
- `ApplicationEncryptionKeyManager#derive_key(label)` derives purpose-specific keys from the application key.
- An example: [`examples/course-subscription`](./examples/course-subscription).

### Upgrading from 0.10

- **`setup` builds two new indexes on existing stores:** a GIN index on `header->'tags'` and a btree index on the event handle. The build blocks appends while it runs. On a large store, create them beforehand with `CREATE INDEX CONCURRENTLY`, using `ES::EventStoreAdapters::Postgres::TAGS_INDEX` and `EVENT_HANDLE_INDEX`. `setup` warns about invalid indexes left by a failed concurrent build.
- **`append(event)` returns the event's position (`Int64`).** It used to return `DB::ExecResult` (Postgres) or the queue entry (in-memory). Code using `.rows_affected` or `.last_insert_id` on it needs to change.
- **Postgres appends run in a transaction with advisory locks.** A plain append costs a few more round trips than before. Plain appends never wait for each other, but they do wait briefly for a conditional append or a `read` of the same boundary. Bulk writers should prefer `append(events)`.
- **All writers must follow the lock protocol** before tag reads or conditional appends are relied on. Upgrade every node writing to the store first; during a rolling upgrade, 0.10 nodes take no locks and write no tags. Don't insert into `eventstore.events` by other means, and leave the events id sequence at its default `CACHE 1`.
- **`define_event` blocks accept only `attribute` and `tag`.** Any other call used to be treated as an attribute silently and is now a compile error.
- **Reserved names on events:** `tags`, `tag_definitions`, `TAG_DEFINITIONS` and the DSL macro `tag`.
- **The in-memory event store refuses an event id that is already stored,** as Postgres always has, instead of overwriting the stored event.
- **Custom event store adapters** keep compiling. To support the new features, implement `read` and the protected `append_batch(events, condition)`. Subclasses of the shipped adapters that override `append(event)` to hook into writes should override `append_batch` instead, which every append now goes through.
- **Configure `ES::Config.tag_hasher` before building event stores** that need it. Stores read it at construction, as they do with `encryption`.
