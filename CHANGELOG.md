# Changelog

## 0.12.2

### Added

- **`ES::Subscriptions.new(kinds:)`** lets an instance process only its reactors (`:reactors`) or only its projections (`:projections`), so they can be deployed and scaled apart. The default is both, as before. Instances record their kinds with their heartbeats, and each kind is shared out among the instances that process it. When every instance processes every kind, all subscriptions are shared out together, as before. Every handler in the bus stays known to an instance that doesn't process it, so `await`, `status` and the operations work for all of them; a reactor can await a projection another instance runs. `catch_up` processes only the instance's kinds. See "Reactors and projections in separate instances" in [docs/subscriptions.md](./docs/subscriptions.md#reactors-and-projections-in-separate-instances).
- **`ES::SubscriptionStore#heartbeat(instance_id, ttl, kinds)`** records an instance's kinds and returns those of every instance alive. Implemented by both adapters. Not abstract: a custom store without it keeps working for instances that process every kind, and an instance with fewer kinds refuses to start on it with `ES::Exception::NotImplemented`.

### Changed

- **The Postgres subscription store's `setup` adds a `kinds text[]` column to `eventstore.subscription_instances`.** Only when missing; the table holds one row per running instance, so the `ALTER TABLE` is quick, but heartbeats wait for it.

### Upgrading from 0.12.1

- **Run `setup`** on the subscription store once, which `ES::Subscriptions#start` does.
- **Upgrade every instance before splitting kinds.** An instance of 0.12.1 records no kinds, and counts every instance alive as one that processes everything. Next to instances with fewer kinds, it would take less than it must, and some subscriptions would be left without an instance. Instances of 0.12.2 log a warning on every rebalance while that's the case.
- **A subclass of a bundled subscription store that overrides `heartbeat(instance_id, ttl)`** is no longer called there: `ES::Subscriptions` now calls `heartbeat(instance_id, ttl, kinds)`. Move the override to that method.
- **Rolling back to 0.12.1** with a stable `instance_id:` (e.g. the host name): 0.12.1 doesn't clear the kinds an instance recorded before. Clear them with `UPDATE "eventstore"."subscription_instances" SET kinds = NULL`, or give the instance a new id. The default ids are new on every start and need nothing.

## 0.12.1

### Added

- **`ES::Subscriptions#catch_up`** runs the subscriptions in the calling fiber until they have processed everything appended so far, including the events reactors append on the way, then returns. It's meant for specs and one-off scripts, in place of `start` and `await`. The guarantees are the same as under `start`. A failing handler's error is raised from `catch_up` instead of being retried, paused subscriptions are left alone, and it raises after `timeout` (30 seconds) if the reactors keep appending events that reach them again. See "Specs and scripts" in [docs/subscriptions.md](./docs/subscriptions.md#specs-and-scripts).
- **`ES::Config.configure { |config| ... }`** sets several values in one block. It yields `ES::Config` itself, so the block takes the same setters, and their order still matters. The configuration docs used this form before it existed; see [docs/configuration.md](./docs/configuration.md).

### Deprecated

- **The queue** (`ES::Queue`, `ES::QueueAdapters::Postgres`, `ES::QueueAdapters::InMemory`) is deprecated as the way to deliver events. Subscriptions replace it; see "Moving from the queue" in [docs/subscriptions.md](./docs/subscriptions.md#moving-from-the-queue). It keeps working and raises no warning yet. It will be removed in a later release.
- `EventBus#publish` is not deprecated, but it's no longer the way to deliver events in production: see [docs/reactors-and-event-bus.md](./docs/reactors-and-event-bus.md#event-bus).

### Changed

- **`ES::Subscriptions#stop`** also releases the database session of subscriptions that were only caught up, never started. Once stopped, they refuse `start` and `catch_up`; create a new `ES::Subscriptions` instead. `stop` on subscriptions neither started nor caught up still does nothing.

### Upgrading from 0.12.0

- No changes needed.

## 0.12.0

### Added

- **Subscriptions** (`ES::Subscriptions`) deliver events to every reactor and projection wired in the `EventBus`, so that several instances of an application can run side by side. Each handler follows the event store from its own saved position. Exactly one instance processes it at a time, and the instances share the handlers out between them through Postgres advisory locks and heartbeats. No broker is needed. A reactor runs in an event store transaction together with the move of its position, so it runs exactly once and its appends commit with it. An `atomic: true` projection applies a batch in one transaction of its own database together with its position. A failing handler is retried with backoff and paused after `max_attempts`, without stopping the others. Includes `configure` (partitions by aggregate, batch size, start position, projection database), `status`, `pause`, `resume`, `skip_failed_event`, `rebuild`, `reset` and `await`. See [docs/subscriptions.md](./docs/subscriptions.md).
- **`EventStore#read_log(after, limit, handles:, partition:)` and `#log_head`** read the store as a log, in the order of the appending transactions and only up to the oldest transaction still running. This is the one read that is safe to resume from a saved position: unlike `read(after:)`, it never skips an event that commits after a later one. Each event carries its `log_position`.
- **`EventStore#transaction { |store| ... }`** runs a block in one transaction with an event store bound to it. Appends through that store commit together or not at all. On Postgres they run in savepoints, so a `Conflict` can be rescued inside the block.
- **`define_projection(..., atomic: true)` and `Projection#write { |connection| ... }`**: a projection whose writes go through `write` commits them together with its subscription position.
- `ES::SubscriptionStore`, with Postgres and in-memory adapters, keeps subscription positions, status, locks and instance heartbeats. Also new: `ES::ProjectionCheckpoints`, `ES::Exception::StaleCheckpoint`, `ES::Config.projection_database?` and `ES::Event#log_position`.

### Changed

- **The Postgres `setup` adds a `transaction_id xid8` column to `eventstore.events`**, with `pg_current_xact_id()` as its default, and the index `events_log_position_idx`. On Postgres 13 or later only; older servers keep working without `read_log`. Existing rows keep no transaction id and read as transaction 0, so no row is rewritten.
- **In-memory event store:** appends now take turns with transactions. An append through the store itself from inside one of its own transactions raises instead of waiting forever.

### Upgrading from 0.11.3

- **Run `setup` once** on each existing Postgres event store. When the column is missing, it is added with an `ALTER TABLE` that doesn't rewrite the table but needs an exclusive lock: it waits for every transaction using the events table, and reads and appends arriving meanwhile queue behind it. `setup` therefore gives up after a 2-second lock timeout and tries 5 times. If the table stays busy, it logs a warning with the statements to run by hand and carries on: the store works as before, and only reading it as a log (subscriptions) refuses until the column exists. The index is then built `CONCURRENTLY`, like the indexes of 0.11.1. To keep boot short on a busy store, run them beforehand at a quiet moment: `ALTER TABLE "eventstore"."events" ADD COLUMN "transaction_id" xid8`, `ALTER TABLE "eventstore"."events" ALTER COLUMN "transaction_id" SET DEFAULT pg_current_xact_id()`, then the index from `LOG_POSITION_INDEX` with `CONCURRENTLY`.
- **A store moved to another cluster** with `pg_dump` or logical replication must have the new cluster's transaction counter past its highest `transaction_id`; reading the log raises otherwise. `pg_upgrade` and physical replicas are not affected.
- No code changes are needed to keep using the queue and `EventBus#publish`. To move to subscriptions, follow [Moving from the queue](./docs/subscriptions.md#moving-from-the-queue): projections one at a time, reactors together in a short write pause. Remove `init: true` from projections run by subscriptions.
- `ES::Subscriptions.start` creates `eventstore.subscriptions`, `eventstore.subscription_instances`, and a `_crystal_es_projection_checkpoints` table in each projection schema. With `listen_url`, it also installs a statement trigger `notify_subscriptions` on `eventstore.events`. That trigger makes every append transaction send a notification, and Postgres commits such transactions one at a time, so it costs append throughput for every writer of the store. Subscriptions need session-mode connections (not PgBouncer in transaction mode) for their advisory locks.
- New reserved names: `write`, `writing_on`, `self.atomic?` and `self.table_schema` in subclasses of `ES::Projection`; `log_position` in subclasses of `ES::Event`. A projection that defines its own `write` overrides the helper.
- Custom event store adapters keep compiling. `read_log`, `log_head`, `transaction` and `subscription_store` raise `NotImplemented` until they implement them.

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
