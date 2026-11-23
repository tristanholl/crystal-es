# Changelog

## 0.11.3

### Added

- **Decision projections** (`ES::DecisionProjection`). A projection declares the events it handles (`on EventClass do |state, event| ... end`) and the tags they must carry (`tags course_id: @course_id`). Its query is derived from those declarations, so the events a decision reads, its fold and its append condition can't drift apart. `on_erased` folds an event whose body was erased, from its header. Invalid declarations are compile errors, among them a handled class that doesn't declare one of the projection's tag keys and so could never match.
- **`EventStore#build_decision_model(**projections)`** composes named projections. It reads all their events in one decision read, folds each projection over the events matching its own query, and returns an `ES::DecisionModel` with the states as a typed named tuple (`model.state[:capacity]`) and the `condition` to append with. It works with every adapter that implements `read_for_decision`.
- The course-subscription example now builds its decision from three projections.

### Upgrading from 0.11.2

- No code changes. Hand-written decision reads keep working.
- New reserved names in subclasses of `ES::DecisionProjection`: the `State` alias, the constants `DECISION_HANDLED`, `DECISION_ERASED` and `DECISION_TAGS`, and the methods `apply_event`, `apply_erased_event`, `apply_stored`, `tag_filter`, `query_item` and `fold`.
- Custom event store adapters get `build_decision_model` for free once they implement `read_for_decision`. The base class gains the protected helpers `event_matches?` and `fold_matching`; an adapter defining methods of those names overrides them.
- The in-memory event store's private `matches?` moved to the base class as `event_matches?`. Only a subclass of `ES::EventStoreAdapters::InMemory` calling it is affected.

## 0.11.2

### Fixed

- **`define_event` compiles when an event declares tags and an attribute with a default** ([#38](https://github.com/tristanholl/crystal-es/issues/38)). The generated constructor put the required `tags:` parameter after every attribute, so a defaulted attribute such as `attribute :extraction_id, UUID?, nil` before it failed with `parameter must have a default value`. `tags:` now sits between the attributes without a default and those with one. Every event that compiled before keeps its parameter order, positional calls included.
- **An attribute without a default declared after one with a default** is now refused with a compile error naming both attributes. It used to fail inside the macro expansion.

### Upgrading from 0.11.1

- No code changes. A tagged event can now keep its attribute defaults; the workaround from #38 (dropping them and passing `nil` explicitly) can be reverted.

## 0.11.1

### Fixed

- **`setup` no longer blocks appends while it adds indexes to an existing Postgres store.** It used to build `events_event_id_idx`, `events_tags_idx` and `events_event_handle_idx` with a plain `CREATE INDEX`, which locks the events table against writes for the whole build. It now builds only the missing ones, with `CREATE INDEX CONCURRENTLY`.
- **`setup` rebuilds an index of its own that a failed concurrent build left invalid,** instead of only warning about it. It builds the replacement under a temporary name (`<name>_rebuild`) and swaps it in once valid, so a unique index keeps enforcing uniqueness throughout. It leaves the index alone while an index build might still be running on the events table, or on Postgres before 12, where builds can't be seen, and keeps warning about every invalid index left.
- **Setups of an existing store running at the same time take turns** through a Postgres session advisory lock. Concurrent setups could fail with `tuple concurrently updated`, and two concurrent index builds on one table deadlock.

### Upgrading from 0.11.0

- No code changes. On a store that lacks the indexes, `setup` still takes as long as the build, and a boot that runs it waits for it. Appends from other instances keep running meanwhile. A concurrent build also waits for every transaction in the database that started before it, so a session left idle in a transaction holds the boot up until it ends. You can still build the indexes yourself beforehand: `setup` builds nothing when they exist and are valid.
- **Run `setup` of an existing store over a session-mode connection,** not through a pooler in transaction mode (PgBouncer `pool_mode = transaction`). The advisory lock is a session lock. Through such a pooler, it can be taken and released on different server sessions and left held, and every later `setup` then waits for it. The wait has no time limit, because a legitimate holder may be building an index for a long time. Every 30 seconds, `setup` logs a warning naming the backend that holds the lock.
- The advisory lock key is `0x6372797365736978`. An application that uses the same key for its own advisory locks makes `setup` wait for them.
- An invalid index named `events_event_id_idx`, `events_tags_idx` or `events_event_handle_idx` is now replaced at the next `setup`. Rename it first if you want to keep it for investigation. As before, building indexes needs a role that owns the events table.

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
