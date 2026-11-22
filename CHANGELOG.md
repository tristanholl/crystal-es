# Changelog

## 0.11.0

### Added

Dynamic consistency boundaries: a consistency boundary can be drawn around the events carrying a set of tags, instead of around one aggregate's stream. Aggregates keep working unchanged.

- **Tags.** `tag :name, Type` inside `define_event` declares a header value that a consistency boundary is queried by. Tags are independent of the body's attributes and are passed to the constructor as `tags: {...}`. `hashed: true` stores an HMAC of the value instead. The key is derived from the application encryption key, and hashing is switched on with `ES::Config.tag_hasher = ES::TagHasher.new(application_key)`. A key declared hashed in one event and plain in another produces a compile-time warning.
- **Query reads.** `EventStore#read(ES::Query, after:, limit:)` returns the events of any of an item's types that carry all of its tags, in append order and with their `position`. An event whose encryption key was destroyed comes back with its header but no body, flagged `body_erased?`.
- **Tag versions.** Every tagged append raises a per-tag version and stamps it into the stored header (`header.tag_versions`). Versions of one tag are gap-free and follow commit order.
- **Decision reads and conditional appends.** `EventStore#read_for_decision(query)` returns the events and the current versions of the query's tags, read in one snapshot. `EventStore#append(events, condition)` appends a batch atomically, and only if every tag the `ES::AppendCondition` names is still at the expected version; otherwise it raises `ES::Exception::Conflict`. Conditions come from a decision read (`decision.condition`), or from versions an eventually consistent read model saw (`expect`, `expect_stored`). A decision read refuses query items that name no tags, including `ES::Query.all`, and condition keys must be declared by an event.
- `ApplicationEncryptionKeyManager#derive_key(label)` derives purpose-specific keys from the application key.
- An example: [`examples/course-subscription`](./examples/course-subscription).

### Upgrading from 0.10

- **`setup` creates the `eventstore.tag_versions` table and builds two new indexes on existing stores.** Tagged appends and decision reads fail until the table exists, so run `setup` (or the DDL in `ES::EventStoreAdapters::Postgres::TAG_VERSIONS_TABLE`) before deploying code that appends tagged events. The table keeps the stored form of every tag value permanently, plaintext for keys not declared `hashed: true`. The indexes are a GIN index on `header->'tags'` and a btree index on the event handle. The build blocks appends while it runs. On a large store, create them beforehand with `CREATE INDEX CONCURRENTLY`, using `ES::EventStoreAdapters::Postgres::TAGS_INDEX` and `EVENT_HANDLE_INDEX`. `setup` warns about invalid indexes left by a failed concurrent build.
- **`append(event)` returns the event's position (`Int64`).** It used to return `DB::ExecResult` (Postgres) or the queue entry (in-memory). Code using `.rows_affected` or `.last_insert_id` on it needs to change.
- **Postgres appends run in a transaction.** A tagged append locks the version rows of its tags, so appends carrying the same tag run one after the other; untagged appends lock nothing. Bulk writers should prefer `append(events)`.
- **All writers must raise tag versions** before conditions are relied on. Upgrade every node writing to the store first; during a rolling upgrade, 0.10 nodes write neither tags nor versions. Don't insert into `eventstore.events` by other means.
- **`define_event` blocks accept only `attribute` and `tag`.** Any other call used to be treated as an attribute silently and is now a compile error.
- **Reserved names on events:** `tags`, `tag_definitions`, `TAG_DEFINITIONS`, the `@tags` instance variable and the DSL macro `tag`. An event declaring tags can't have an attribute named `tags`, since that name is its constructor argument.
- **The in-memory event store refuses an event id that is already stored,** as Postgres always has, instead of overwriting the stored event.
- **Custom event store adapters** keep compiling. To support the new features, implement `read`, `read_for_decision` and the protected `append_batch(events, condition)`, which must raise and stamp tag versions. Subclasses of the shipped adapters that override `append(event)` to hook into writes should override `append_batch` instead, which every append now goes through.
- **`event.tags` holds only the plaintext tags an event was built with.** Events read back carry their tags only in `header.tags`, in stored form (digests for hashed tags). Appending a read-back event again keeps those stored tags unchanged, so copying events into a store with a different application key leaves their hashed tags unfindable there.
- **Configure `ES::Config.tag_hasher` before building event stores** that need it. Stores read it at construction, as they do with `encryption`.
