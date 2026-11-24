# Event delivery across instances: required changes per option

Companion to [multi-instance-event-delivery.md](./multi-instance-event-delivery.md), which describes
the problem, the requirements (R1–R8) and the shared building blocks (§3.1–3.6). This document lists
**what has to change** for each option A–I, in the library (crystal-es), the consuming application and the
infrastructure. Options **C (Postgres subscriptions)** and **F (LavinMQ/RabbitMQ)** get a full design,
split by **reactors** and **projections**.

Written against crystal-es 0.11.3 and a production application built on it, as of 2026-11-24.

---

## 0. Baseline: what reactors and projections do today

| | Reactors (~125 in the application) | Projections (~55 in the application) |
|---|---|---|
| Purpose | Turn an event into a command (`CommandHandler#handle`). They hydrate aggregates through the injected `@event_store` and sometimes read projections (e.g. `Orders::Reactors::Fulfilment::OnPlaced` calls `Customers::Queries::Customers`). | Fold events into tables in `projections.*`. Each `apply` opens its own `@projection_database.transaction`, and some hydrate aggregates through the default `ES::Config.event_store`. |
| Writes go to | The event store DB (appends), plus the pgmq jobs queue (the jobs database) via `Jobs.enqueue` in command handlers | The projection DB (the projection database) |
| Delivery today | One pgmq message per event. `EventBus#publish` runs every subscriber in subscription order. Any raise archives the message for **all** subscribers. | Same as reactors. `init: true` replays into an empty table in a background fiber. |
| Idempotency today | Mostly domain state checks in the command handlers (`InvalidState`/`Conflict` on a repeat) | Mostly none. `INSERT` on `…Requested` hits a unique index on a repeat and raises. |
| Implicit coupling | Runs in the same loop as projections, so it usually sees projections that are "fresh enough" | Shares a failure fate with every reactor subscribed to the same event |

The last row matters. **Every option that runs handlers independently removes the implicit
coupling.** Projections can lag reactors and the other way round. Reactors that read projections must
tolerate that, or wait explicitly (C can offer an explicit wait; F cannot, see §2.4 and §3.4).

---

## 1. Short change lists for every option

Each list is complete enough to estimate, but not a design. C and F follow in full in §2 and §3.

### A. Single active dispatcher (leader lock)

| Area | Changes |
|---|---|
| Library | Optional: `ES::Queue#listen` gains a `leader_lock : DB::Database?` parameter, and `Projection#init` is guarded by the same lock. If added as a library helper, it is a new method with a default, so no break. |
| Platform | `start_queue_listener` loops `pg_try_advisory_lock` on a dedicated connection and only consumes while holding it. The `init` calls move behind the same lock. Replace `queue.archive` on error with "retry with backoff, archive after N reads" (`read_ct` is already on `Queue::Entry`). |
| Infra | None. A direct (non-pooled) DB connection for the lock. |
| Reactors | Unchanged code. **Benefit:** no concurrent double execution across instances. With retry instead of archive, a transient failure no longer drops workflow steps. |
| Projections | Unchanged code. **Benefit:** no out-of-order apply and no parallel `init`. |
| Limits | Processing doesn't scale. Fan-out coupling and the lack of checkpoints remain. |

### B. pgmq fan-out (one queue per handler)

| Area | Changes |
|---|---|
| Library | `ES::QueueAdapters::Postgres#setup(handlers)` creates one pgmq queue per subscriber, and a trigger (or router function) sends to every queue whose subscriber handles the event's `event_handle`, from a routing table synced from `EventBus#routes`. A new `ES::HandlerQueueConsumer` runs one handler per queue under an advisory lock (for ordering), retries with `read_ct` backoff and extends the visibility timeout for slow handlers (`pgmq.set_vt`). |
| Platform | Start one consumer per handler queue (~180 queues). A routing-table sync runs on boot. |
| Infra | None. Expect vacuum and bloat tuning on ~180 pgmq tables. |
| Reactors | A transactional inbox: `pgmq.delete` plus the reactor's appends in one transaction. pgmq is in the same DB, so this is possible if the jobs database equals the event store database. The event store needs to join an outer transaction (as in C, §2.2.4). **Benefit:** per-reactor isolation and retries. |
| Projections | Idempotent writes or a receipt per event. Backfill for new or rebuilt projections must come from `each_event` with a handover to the queue (deduplicate by `event_id`). **Benefit:** isolation. **Cost:** no native replay. |
| Limits | One message per event per subscriber. Ordering only with a single consumer per queue. |

### C. Postgres catch-up subscriptions (recommended). Full design in §2.

| Area | Summary |
|---|---|
| Library | `xid8` column and position, `read_all`, subscription and checkpoint tables, a runner with advisory locks, NOTIFY and a shared tail reader, a transaction-bound event store, and a projection `write` helper |
| Platform | Replace `start_queue_listener` with the runner, one cutover, mechanical projection edits |
| Infra | None |

### D. Logical replication read by the application

| Area | Changes |
|---|---|
| Library | Everything in C **except** the `xid8` column and watermark. In their place, a replication-protocol client: CopyBoth streaming plus `pgoutput` decoding, which crystal-pg does not implement, so you write or shell out to `pg_recvlogical`. A slot manager (create, drop, advance `confirmed_flush_lsn` only after every subscription has persisted past it). Backfill still uses `read_all` from C. |
| Platform | Same as C, plus a replication user and a direct, unpooled connection. |
| Infra | `wal_level=logical`, `max_replication_slots`, `max_slot_wal_keep_size`, and alerting on slot lag (an inactive slot retains WAL until the disk fills). |
| Reactors / Projections | Same changes and benefits as C. The only gain is lower latency and no polling. |

### E. Kafka (or Redpanda)

| Area | Changes |
|---|---|
| Library | Core: C phase 1 (`read_all` with watermark) to drive the relay, and a transaction-bound event store for the reactor inbox. A new shard `crystal-es-kafka` holds the producer relay (key `aggregate_id`, idempotent producer, header-only or header plus ciphertext payload) and a consumer runner. Partitions map to consumer-group members. Offsets are stored **in the DB, inside the handler transaction**, not committed to Kafka. Rebalance callbacks load offsets on assignment. **No maintained Crystal Kafka client is known.** Expect librdkafka FFI bindings (`lib LibRdKafka … end`) that you maintain. |
| Platform | Run the relay as a subscription. Use one consumer group per handler (~180 groups) or group handlers per bounded context into fewer groups. Set topic partition counts. |
| Infra | A Kafka/KRaft (or Redpanda) cluster in production, compose and CI, plus monitoring, retention policy and ACLs. Optionally Debezium and Kafka Connect instead of the in-app relay. |
| Reactors | Inbox: `(reactor, event_id)` receipt in the event store transaction (as in F, §3.3). **Benefit:** scale by partitions, broker-managed rebalancing. |
| Projections | Offset or position checkpoint in the projection DB transaction. Rebuild: replay from Postgres (`read_all`), or from Kafka if retention is infinite. **Benefit:** consumer lag tooling, and external consumers can use the same topic. |

### F. RabbitMQ / LavinMQ. Full design in §3.

| Area | Summary |
|---|---|
| Library | A relay from the existing pgmq outbox to the broker, topology generated from routes, a consumer runner on `amqp-client.cr`, an inbox and receipts, and a transaction-bound event store |
| Platform | Relay plus consumers, DLQ handling, cutover |
| Infra | A LavinMQ (or RabbitMQ) node or cluster |

### G. SNS FIFO → SQS FIFO

| Area | Changes |
|---|---|
| Library | A new shard with an SNS publisher relay (`MessageGroupId = aggregate_id`, `MessageDeduplicationId = event_id`) driven by the pgmq outbox relay (§3.2.1) or `read_all`, and an SQS long-poll consumer runner. SigV4-signed HTTP calls, because no full Crystal AWS SDK is available. The inbox is the same as in F. |
| Platform | One SQS FIFO queue per handler with subscription filter policies on `event_handle` (generated from routes, managed via IaC), DLQ redrive policies. |
| Infra | AWS account, IAM, IaC, and LocalStack for dev and CI. |
| Reactors / Projections | Same inbox and receipt patterns as F. Message groups give per-aggregate ordering with parallelism, without a single-active-consumer setting. **Cost:** a 5-minute deduplication window only, FIFO throughput quotas, per-request pricing, and lock-in that contradicts the self-hosted stack. |

### H. NATS JetStream / Redis Streams

| Area | Changes |
|---|---|
| Library | A new shard with a relay (from the pgmq outbox or `read_all`) to the subjects `events.<aggregate_type>.<handle>` (JetStream, `Nats-Msg-Id = event_id`) or `XADD` (Redis), and a consumer runner: a JetStream durable pull consumer per handler with `max_ack_pending=1` for ordering, or a Redis consumer group per handler with `XAUTOCLAIM` for crashed consumers. The inbox is the same as in F. |
| Platform | Consumer configuration generated from routes. |
| Infra | A NATS cluster with JetStream storage, or Redis/Valkey with AOF. |
| Reactors / Projections | Same patterns as F. JetStream adds replay from a sequence (like F streams). Redis Streams has memory-bound retention, so rebuilds come from Postgres. |

### I. Hybrid: C inside, pluggable publishers outside

| Area | Changes |
|---|---|
| Library | All of C, plus an `ES::Publisher` interface (`publish(batch : Array(ES::EventStore::Event)) : Nil`, idempotent by `event_id`) and a `PublisherSubscription` that runs a publisher like any other subscription. Adapters (Kafka, NATS, AMQP, SNS) live in separate shards. |
| Platform | Choose which events are "integration events" (a filter on the publisher subscription) and configure one adapter. |
| Reactors / Projections | Identical to C. Only *external* consumers use the broker. |

---

## 2. Option C in depth: the event store is the stream

### 2.1 Target behaviour

```
                   ┌───────────────────────── instance k ─────────────────────────┐
 appends ─▶ events │ LISTEN crystal_es_events ─▶ wake                             │
   (+xid8)         │ tail reader: read_all(after: min(caught-up ckpts), ≤ watermark)
                   │   └─ fan-out in memory ─▶ subscriptions this instance holds:  │
                   │        proj:Orders        🔒 batch → write + checkpoint (proj DB tx)
                   │        reactor:OnRequested 🔒 per event → appends + checkpoint (ES tx)
                   │        reactor:Billing#2 🔒 partition 2 of 4               │
                   │   lagging subscriptions read on their own until caught up    │
                   └──────────────────────────────────────────────────────────────┘
```

- Every handler class becomes a **subscription**, named `reactor:<Class>` or `projection:<Class>`,
  optionally split into partitions `#0..#P-1`.
- Each subscription has **one active consumer cluster-wide** (an advisory lock per subscription or
  partition), its own **checkpoint**, and its own error state.
- **Routing stays in the bus wiring file.** The runner derives each subscription's
  event-handle filter from `EventBus#routes`, so the wiring file doesn't change.

### 2.2 Library changes (crystal-es)

#### 2.2.1 Schema: event store database (applied in `setup`, including the existing-store branch)

```sql
-- additive, no table rewrite, no UPDATE of existing rows
ALTER TABLE eventstore.events ADD COLUMN IF NOT EXISTS transaction_id xid8;
ALTER TABLE eventstore.events ALTER COLUMN transaction_id SET DEFAULT pg_current_xact_id();
CREATE INDEX CONCURRENTLY IF NOT EXISTS events_transaction_position_idx
  ON eventstore.events ((COALESCE(transaction_id, '0'::xid8)), id);

CREATE TABLE IF NOT EXISTS eventstore.subscriptions (
  name             TEXT PRIMARY KEY,          -- 'reactor:Customers::Reactors::Onboarding::OnVerified#0'
  checkpoint_tx    BIGINT      NOT NULL DEFAULT 0,  -- xid8 read as ::text::bigint (crystal-pg has no xid8 decoder)
  checkpoint_id    BIGINT      NOT NULL DEFAULT 0,
  status           TEXT        NOT NULL DEFAULT 'running',  -- running | failing | paused
  attempts         INT         NOT NULL DEFAULT 0,
  failed_event_id  UUID,
  last_error       TEXT,                       -- message only, never bodies or keys (AGENTS.md)
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- wake-up hint; transactional, so it's delivered on commit and coalesced per transaction
CREATE OR REPLACE FUNCTION eventstore.notify_events() RETURNS trigger AS $$
BEGIN PERFORM pg_notify('crystal_es_events', ''); RETURN NULL; END $$ LANGUAGE plpgsql;
CREATE OR REPLACE TRIGGER notify_events AFTER INSERT ON eventstore.events
  FOR EACH STATEMENT EXECUTE FUNCTION eventstore.notify_events();
```

Projection checkpoints live **next to the projection data**. A table
`"<schema>"._crystal_es_projection_checkpoints` with the same columns, created by `ProjectionMeta#setup`
alongside `_crystal_es_projection_metadata`, makes "rows plus checkpoint" one transaction even when
the projection database is a different database or server.

#### 2.2.2 Reading the log

```crystal
struct ES::EventStore::Position
  include Comparable(Position)
  getter transaction_id : Int64
  getter id : Int64
  ZERO = new(0_i64, 0_i64)
end

abstract class ES::EventStore
  # Events strictly after `after`, from finished transactions only, in (transaction_id, id) order.
  # Never returns a position that a later call could precede. Default raises NotImplemented.
  def read_all(after : Position, limit : Int32, handles : Array(String)? = nil) : Array(Event)
  # Highest position currently safe to read (for lag metrics and catch-up termination)
  def head : Position
end
```

- Postgres: the watermark query from §3.1 of the main document. `handles` adds
  `header->>'event_handle' = ANY($n)`. The result also reports the last position *scanned*, so a
  filtered subscription advances past events it ignores.
- In-memory: `transaction_id = 0`, `id = array index`. Appends are atomic under the store's mutex, so
  every stored event is immediately safe. Shared specs prove parity.
- `ES::EventStore::Event` gains a `position : Position?` getter (nil where unknown). This is additive.
- `each_event` and `last_event_id` stay as they are, so existing callers are unaffected.

#### 2.2.3 Runner, locks, checkpoints

New files under `src/components/subscriptions/`:

| Type | Responsibility |
|---|---|
| `ES::Subscription` (abstract) | `name`, `handles : Array(String)`, `partitions : Int32`, `batch_size`, `checkpoint_store`, `process(batch, partition)` |
| `ES::ReactorSubscription(R)` | One event per transaction: reactor call plus checkpoint in the event store transaction (§2.3) |
| `ES::ProjectionSubscription(P)` | N events per transaction: applies plus checkpoint in the projection DB transaction (§2.4) |
| `ES::CheckpointStore` (abstract) + `Postgres` / `InMemory` | `load(name) : Position`, `save(connection, name, position)`, `fail(name, event_id, error)`, `reset(name)` |
| `ES::Subscriptions::LockManager` | One **dedicated session connection** per instance. `pg_try_advisory_lock(hashtext(name))` per subscription or partition. A periodic acquire loop (with a cap per instance for spread) and release on shutdown. Advisory locks are session-scoped and hold no transaction open, so they don't hold back `xmin`. |
| `ES::Subscriptions::TailReader` | Wakes on NOTIFY (`PG.connect_listen`) or on a fallback poll (for example every 2 s). Reads one batch after the minimum checkpoint of its caught-up subscriptions and fans it out in memory. Lagging subscriptions get their own catch-up fiber until they reach `head`. |
| `ES::Subscriptions::Runner` | Builds subscriptions from `EventBus#routes`, applies per-subscription settings (partitions, batch size, retry policy), starts and stops (graceful: finish the current batch, release the locks), exposes `status`/`lag`. |

Failure policy, the same for both handler types: on a raise, roll back the transaction. Set the
subscription status to `failing` with `attempts`, `failed_event_id` and `last_error`, back off
exponentially, and retry **the same event**. Order is never broken by skipping. After N attempts it
moves to `paused`, which needs an operator to `resume` or `skip(event_id)`. The skip is explicit and
logged. Only that subscription (or partition) stops. Everything else continues.

#### 2.2.4 Transaction-bound event store (needed by reactors, and reused by F, B and E)

`Postgres#append_batch` opens `@db.transaction` and sets `READ COMMITTED` as its first statement. Add:

```crystal
abstract class ES::EventStore
  # Runs the block in one database transaction and yields an event store bound to it: reads see the
  # transaction's own writes, appends join it (as a savepoint, so a Conflict rolls back only the append).
  # Default raises NotImplemented.
  def transaction(& : EventStore ->) ; end
end
```

- Postgres: a private subclass or wrapper holding a `DB::Transaction`. `append_batch` uses
  `tx.transaction` (crystal-db turns a nested call into a savepoint) and skips the
  `SET TRANSACTION`, because the outer transaction already set it. `fetch_events`, `read`,
  `read_for_decision` and `fetch_event` run on `tx.connection`.
- In-memory: buffer appends and commit them on block exit under the mutex, discarding on raise.
- This is the main new public API. It also benefits ordinary command handlers that today append
  twice non-atomically.

#### 2.2.5 Projection changes

- New protected helper in `ES::Projection`:

  ```crystal
  # Joins the subscription's batch transaction when one is running (atomic with the checkpoint),
  # otherwise opens its own transaction exactly like today.
  protected def write(& : DB::Connection ->)
  ```

  It is additive. Existing `@projection_database.transaction` blocks keep compiling and working.
- Atomicity is opt-in. A projection whose every `apply` goes through `write` is marked
  `define_projection …, atomic: true`. A compile-time check is hard here, so the runner verifies at
  runtime that no `@projection_database.transaction` ran during the batch, and raises otherwise
  (fail loudly). Non-atomic projections run with **batch size 1** and checkpoint right after: at most
  one event is re-applied after a crash, so those applies must tolerate that, as they must today.
- `init: true` and `Projection#init` are superseded. A new subscription starts at `Position::ZERO`,
  which *is* the backfill, without racing the live tail. `init` stays as a deprecated no-op path for
  applications not using the runner.
- `replay(truncate: true)` becomes `runner.rebuild(ProjectionClass)`: take the lock, truncate, reset
  the checkpoint, and catch up. Only that projection's readers see the rebuild.
- Later and optional: **blue/green rebuild** keyed on the projection fingerprint (a versioned table
  plus a view swap). This requires the DSL to support versioned table names and is the follow-up for
  the "projection schemas are immutable" invariant.

#### 2.2.6 What stays and what's deprecated

- `ES::EventBus` stays: it is the routing table, and `publish` stays for specs and for applications
  without a runner.
- The `ES::Queue` adapters stay (they are a public base class), but the `queue_event_<name>` trigger
  is no longer needed for delivery. Add `ES::QueueAdapters::Postgres#teardown_trigger` for the
  cutover. Deprecate in the CHANGELOG.
- This is a minor version bump, with upgrade notes: migration, index build time, the cutover
  procedure, `pg_monitor` grants on the new tables, and the need for a direct connection for locks.

### 2.3 Reactors under C

**Required changes**

| Where | Change |
|---|---|
| Reactor classes | **None.** The runner constructs `R.new(event_store: bound, event_handlers: …)`, so every hydration and every command handler the reactor calls with `event_store: @event_store` joins the transaction. |
| Reactors that use the default store | A command handler built without passing `event_store:` falls back to `ES::Config.event_store` and escapes the transaction. Audit with `grep -L 'event_store: @event_store'` over reactors. The runner can also set a fiber-local "current transaction" that `ES::Config.event_store` honours, as a safety net. |
| Reactors reading projections | `Customers::Queries::Customers` and similar can now be stale by the projection's lag. Options: (a) hydrate the aggregate instead (preferred), (b) explicitly wait: `ES::Subscriptions.await(Customers::Projections::Customers, event.position, timeout: 5.seconds)`, which is possible because positions are comparable, (c) accept staleness where it is cosmetic, such as display labels. |
| Side effects (`Jobs.enqueue`) | If the jobs database is the event store database, give the jobs adapter an `enqueue(job, connection:)` overload so the enqueue joins the reactor transaction. This removes today's "event appended but job lost" (or the reverse) window. Otherwise keep the jobs at-least-once and idempotent, as `Jobs` already documents. |
| Hot reactors | `runner.partition(Invoices::Reactors::Billing::OnOrderPlaced, 4)` partitions by `hash(aggregate_id)`. Use this only where measured. |
| Wiring | the bus wiring file is unchanged. `start_queue_listener` becomes `start_subscriptions`. |

**Per-event processing**

```crystal
event_store.transaction do |bound|
  reactor_class.new(event_store: bound, event_handlers: handlers).call(event)  # appends join the tx
  checkpoints.save(bound.connection, name, event.position)                     # same tx
end                                                                            # commit = done, exactly once
```

**How behaviour improves**

| Situation | Today | Under C |
|---|---|---|
| Two instances running | Both consume the queue, so the same workflow step can run twice, and steps for one aggregate run out of order | Exactly one instance runs each reactor (or partition), in commit order per aggregate |
| Reactor raises | The message is archived, so this reactor **and every later subscriber of the event** never run. The workflow silently stalls. | Rolled back and retried with backoff. Only this reactor waits. Nothing is dropped, and `failing` status plus `last_error` are visible. |
| Instance crashes mid-reactor | The message reappears after 30 s. Steps that already committed run again (relying on domain checks). | The transaction never committed, so the next lock holder (seconds later) re-runs it from the checkpoint. **Effectively once.** |
| Reactor appends twice (two command handlers) | Two separate transactions. A crash between them leaves half a workflow step. | Both appends and the checkpoint commit together, or none do |
| Slow reactor (e.g. assembling a notification payload) | Delays every handler of every event behind it | Delays only itself. Others run in parallel on other instances or fibers. |
| Deploy or rolling restart | Messages in flight are invisible until their visibility timeout expires, and duplicates are possible | Graceful shutdown releases locks after the current event, and another instance takes over immediately |
| Scaling | Not possible | Add instances: locks spread across them. Add partitions for one hot reactor. |
| Tracing | None | Optional `causation_id` (source event) in emitted event headers, set by the runner through the bound store |

**Things to accept**
- Reactor transactions must stay short: they are writing transactions and hold `xmin` while open.
  Anything slow (HTTP, third-party APIs, mail) stays in jobs, which the application already does.
- A conflict in one command now rolls back the whole reactor step. That is the correct unit, but it
  changes error surfaces.

### 2.4 Projections under C

**Required changes**

| Where | Change |
|---|---|
| Projection `apply` blocks | Mechanical: `@projection_database.transaction do |tx| cnn = tx.connection … end` becomes `write do |cnn| … end`, then mark the projection `atomic: true`. This applies to all projections and can be done one at a time. |
| Projections that hydrate aggregates | `::Orders::Aggregate.new(aggregate_id)` uses `ES::Config.event_store`. Reading committed history outside the projection transaction is fine, because the event being applied is below the watermark and therefore committed. No change. |
| `init: true` | Becomes irrelevant (the subscription starts at zero) and can be removed later. |
| Projections in other stores | Implement a `CheckpointStore` for the target (a document in the same index or bucket, or a row in that store's DB), or keep the checkpoint in Postgres and make the writes idempotent by `event_id`/position. Batch size is per subscription. |
| Read endpoints | Unchanged. Optional: `ES::Subscriptions.lag(Projection)` for a "data as of" indicator or health check. |

**Per-batch processing**

```crystal
projection_db.transaction do |tx|
  projection = P.new(projection_database: projection_db)   # write { } joins tx
  projection.with_batch_transaction(tx) do
    batch.each { |event| projection.call(event) }           # ordered by position
  end
  checkpoints.save(tx.connection, name, batch.last_scanned_position)
end
```

**How behaviour improves**

| Situation | Today | Under C |
|---|---|---|
| Two instances running | Events of one aggregate are applied in parallel and out of order, so `Accepted` can be applied before `Requested` (an `UPDATE` with no row, then an `INSERT`: wrong status). | One applier per projection, strictly in position order |
| Projection raises (bug, constraint) | The event is archived for all subscribers. The projection is silently wrong forever, and reactors on the same event are skipped too. | Only this projection stops at that event with `failing` status. Fix and deploy, and it resumes where it stopped, so no data is lost. Reactors are unaffected. |
| Crash mid-apply | The message reappears and the projection `INSERT` raises on the unique index, so the event gets archived | For atomic projections, the batch rolls back and is re-applied exactly once. Non-atomic: at most one event is re-applied. |
| New projection | `init` runs on every instance that sees an empty table (duplicates) and races the live queue | Starts at zero on one instance, catches up at batch speed, and joins the shared tail when level |
| Rebuild after a bug or schema change | `replay(truncate: true)` manually, racing live delivery | `runner.rebuild(P)`: locked, truncated, replayed, and others unaffected (blue/green later) |
| Throughput | One event per transaction, sequential behind every other handler | 500 events per transaction, a separate fiber per projection, spread over instances |
| Different persistence layer | Only `ES::Config.projection_database` in practice | Each projection has its own database or store and its own checkpoint, so moving a projection to a reporting DB means pointing it there and letting it rebuild |
| Observability | None | Lag per projection (`head − checkpoint`), status, last error |

### 2.5 Application changes

1. Server start-up: replace `start_queue_listener` with `start_subscriptions`. Build the runner
   from `ES::Config.event_bus`, a direct (unpooled) connection for locks, a LISTEN connection, and
   per-subscription settings (a subscriptions initializer).
2. Migrate the projections to `write { }` (mechanical, any order).
3. Audit reactors: the injected store is passed everywhere, and reactors that read projections are
   reviewed (§2.3).
4. Jobs: decide whether the jobs database is the event store database. If it is, add a transactional
   `enqueue`.
5. Operations: a `subscriptions status|pause|resume|skip|rebuild` CLI, lag and `xmin`-age
   metrics, and `statement_timeout`/`idle_in_transaction_session_timeout` on application roles.
6. Specs: keep `ES::Config.event_bus.publish` for unit specs. Add an integration spec that runs the
   runner against the in-memory store.

### 2.6 Cutover (once, per environment)

- **Projections can migrate one at a time without a pause.** Unsubscribe a projection from the bus,
  truncate it, and register it as a subscription from `Position::ZERO`. It rebuilds while the others
  keep running on the old pipeline. This is the safest first step and proves the runner in
  production.
- **Reactors migrate together, in a short write pause**, because they can't be replayed:
  1. Put the app in maintenance mode for writes (reject commands for a few seconds). Reads stay up.
  2. Wait until the pgmq queue is empty and no writing transaction is open (`pg_snapshot_xmin` equals
     `pg_current_xact_id`).
  3. Set every reactor checkpoint to `head`. Drop the `queue_event_default` trigger.
  4. Start the runner for the reactors, then resume writes.

  Without a pause, an event committed around the switch could be handled by both pipelines or by
  neither.

### 2.7 Effort (C)

| Phase | Scope | Size |
|---|---|---|
| C1 | `xid8` column and index, `Position`, `read_all`/`head`, in-memory parity, shared specs | S–M |
| C2 | `CheckpointStore`, `LockManager`, `TailReader`, `Runner`, failure policy, projection `write` helper; projections migrate one at a time | M |
| C3 | `EventStore#transaction` (bound store), `ReactorSubscription`, partitions, `await`, reactor cutover | M |
| C4 | Operations CLI, metrics, blue/green rebuild (optional) | S–M |

---

## 3. Option F in depth: LavinMQ (or RabbitMQ)

LavinMQ features this design relies on, verified against its documentation:
[single active consumer](https://lavinmq.com/documentation/single-active-consumer) on queues (not on
streams), a native [consistent-hash exchange](https://www.lavinmq.com/documentation/consistent-hash-exchange)
that can hash on a header and needs no plugin (RabbitMQ needs one), and
[stream queues](https://lavinmq.com/documentation/streams) with
[server-side offset tracking and filtering](https://lavinmq.com/documentation/server-side-offset-tracking-and-stream-filtering).
LavinMQ is written in Crystal, and 84codes maintains the Crystal client `amqp-client.cr`.

### 3.1 Target behaviour

```
appends ─▶ events ─trigger─▶ pgmq "outbox" (exists today)
                                   │ relay (1 active instance, advisory lock), publisher confirms
                                   ▼
              exchange es.events (topic, routing key = event_handle,
                                  message_id = event_id, header aggregate_id)
     ┌──────────────┬──────────────┴───────────────┬─────────────────────────────┐
     ▼              ▼                              ▼                             ▼
 q: es.reactor.   q: es.projection.     x: es.reactor.Billing.hash   (optional) stream es.log
 OnPlaced         Orders                (x-consistent-hash on aggregate_id)   for replay
 SAC, DLX         SAC, DLX                ├─ q …#0 SAC   ├─ q …#1 SAC
     │              │                       ▼              ▼
 instance holding  instance holding     consumers per partition
 the active consumer
```

- Each handler gets a durable queue with `x-single-active-consumer: true`. Every instance subscribes
  to every queue. The broker activates one consumer and fails over to the next on disconnect, keeping
  order.
- Bindings are generated from `EventBus#routes`: queue `es.<kind>.<Class>` is bound to `es.events`
  once per event handle it handles.
- Hot handlers get a per-handler consistent-hash exchange (bound to `es.events` for the same handles),
  hashing on the `aggregate_id` header, with P single-active-consumer queues behind it. This gives
  per-aggregate order and P-way parallelism.

### 3.2 Library changes

Core crystal-es changes are small. The broker code goes into a separate shard, `crystal-es-amqp`, so
the core stays dependency-free (§I).

#### 3.2.1 The relay: reuse the existing outbox

The pgmq trigger is already a correct transactional outbox, and a **single sequential relay** reading
it preserves per-aggregate order. Version n+1 can only be appended after version n committed, so its
message is always visible to the relay first. Global order across aggregates may differ from commit
order, which is acceptable because the broker doesn't promise more. **F therefore doesn't need the
`xid8` column.** That is a real advantage over C's first phase.

```crystal
# crystal-es-amqp: ES::AMQP::Relay
loop do
  batch = outbox.read(timeout: 30.seconds, count: 500)                  # pgmq, ordered by msg_id
  batch.each do |msg|
    channel.basic_publish_confirm(body: msg.header.to_json, exchange: "es.events",
      routing_key: msg.header.event_handle,
      props: {message_id: msg.header.event_id, delivery_mode: 2,
              headers: {"aggregate_id" => msg.header.aggregate_id}})   # confirm before delete
    outbox.delete(msg.msg_id)
  end
end
```

- One active relay cluster-wide (an advisory lock, as in option A). A crash between the confirm and
  `delete` republishes, so delivery is **at-least-once**, and consumers deduplicate by `message_id`.
- The payload is **the header only**, as today. Consumers fetch the stored event (`fetch_event` by
  `event_id`, an indexed lookup), so bodies, including encrypted ones and personal data, never enter
  the broker. That is consistent with the AGENTS.md rules on secrets and personal data. The cost is
  one primary-key read per handler per event.
- Core change: `ES::Queue` needs a public `read` (it is `protected` in the Postgres adapter today) or
  a `drain(&)` helper. This is additive.

#### 3.2.2 Topology management

`ES::AMQP::Topology.sync(bus : EventBus, partitions : Hash(Class, Int32))` declares the exchange,
queues (`x-single-active-consumer`, `x-dead-letter-exchange: es.dlx`, `x-queue-type` classic or
quorum on RabbitMQ), consistent-hash exchanges and bindings, and removes bindings for routes that no
longer exist. It runs on every boot and is idempotent, which fits the `setup` philosophy.

Changing P for a handler means a new set of queues: drain the old ones first, the same as changing
Kafka partitions.

#### 3.2.3 Consumer runner and inbox

- `ES::AMQP::Runner` subscribes to every handler queue with manual acks and `prefetch` (1 for
  reactors, N for projections). It acks **only after the database transaction commits**.
- Deduplication receipts, because broker delivery is at-least-once:
  - reactors: `eventstore.reactor_receipts (handler TEXT, event_id UUID, processed_at TIMESTAMPTZ, PRIMARY KEY (handler, event_id))`
    in the event store database,
  - projections: the same table shape in the projection database (`_crystal_es_projection_receipts`).
  - Pruning: delete receipts older than the maximum redelivery horizon (for example 14 days, to cover
    manual DLQ redrives). Redriving older messages must be refused, which the runner checks against
    `event.created_at`.
- **Core change shared with C:** `ES::EventStore#transaction` (the bound store, §2.2.4), so a reactor's
  appends and its receipt commit together.
- Retry policy. Ordering and dead-lettering conflict:
  - in-process retries with backoff first (the message stays unacked, so the single active consumer
    keeps the queue blocked and order holds),
  - then either **park**: stop consuming that queue and alert (order preserved, recommended for
    projections and most reactors), or **dead-letter** with `basic.reject` (the queue continues, but
    later events of the same aggregate overtake the failed one, acceptable only for reactors marked
    `order_insensitive`).

#### 3.2.4 Replay and backfill (projections)

Classic queues don't replay, so there are two designs:

- **F-a, backfill from Postgres plus a queue handover (recommended):**
  1. Declare and bind the new projection's queue **first**, so it buffers live events.
  2. Backfill from `each_event` into the projection, recording receipts for every applied `event_id`
     (or comparing `aggregate_version` per row).
  3. Start consuming the queue. Events already applied during the backfill are skipped by receipt.

  This uses the existing `each_event`, so no `xid8` column is needed.
- **F-b, a stream queue `es.log` as the replay source:** bind a stream queue to `es.events` (`#`) with
  infinite retention, seeded once by republishing history from Postgres. Rebuilds consume it from
  `x-stream-offset: first` with `x-stream-filter` on the handles. Streams don't support single active
  consumer, so a rebuild must run under an application lock. This duplicates the event store in the
  broker, which is only worth it if external consumers also need replay.

### 3.3 Reactors under F

**Required changes**

| Where | Change |
|---|---|
| Reactor classes | **None.** As in C, the runner injects the bound store. The same audit applies to reactors that build command handlers without `event_store: @event_store`. |
| Runner per message | `fetch_event` → `materialize` → in the event store transaction: check the receipt (skip if present), `call`, insert the receipt → commit → `ack` |
| Reactors reading projections | Same staleness as in C, but **without an `await` primitive**. Broker positions aren't comparable to the projection's progress, so (a) hydrate instead of querying, or (c) accept staleness. |
| Hot reactors | Partition via the consistent-hash exchange (P queues, single active consumer each) |
| Non-ordered reactors | May opt out of single active consumer and use competing consumers for throughput, with `basic.reject` to the DLQ after N attempts |
| `Jobs.enqueue` | Same as C: join the transaction if the jobs database is the event store database. Or move jobs to the broker too (delayed retries via TTL and DLX). That is optional and a separate decision. |

```crystal
queue.subscribe(no_ack: false) do |msg|
  event = materialize(event_store.fetch_event(UUID.new(msg.properties.message_id.to_s)))
  event_store.transaction do |bound|
    next if receipts.seen?(bound.connection, name, event.header.event_id)
    reactor_class.new(event_store: bound, event_handlers: handlers).call(event)
    receipts.record(bound.connection, name, event.header.event_id)
  end
  msg.ack                     # crash before this line → redelivery → receipt found → ack
end
```

**How behaviour improves**

| Situation | Today | Under F |
|---|---|---|
| Two instances running | Duplicate and out-of-order workflow steps | The broker activates one consumer per reactor queue. Order per queue (or per partition) holds. |
| Reactor raises | Dropped for all subscribers | Retried in place. Then parked (order kept) or dead-lettered (visible in the broker UI, redrivable). Other reactors are unaffected. |
| Instance crashes | 30 s invisibility, duplicates | The broker redelivers unacked messages to the next consumer immediately. The receipt makes it **effectively once**. |
| Failover mechanism | n/a | **Broker-managed** (single active consumer), so no Postgres session locks and it works behind a transaction-pooling PgBouncer |
| Scaling | n/a | Consistent-hash partitions, competing consumers for order-insensitive reactors |
| Visibility | Logs only | Per-queue depth, rates, unacked and DLQ counts in the LavinMQ UI and metrics, free |
| Latency | ≤ 100 ms poll | Relay poll interval (pgmq read, about 100 ms) plus broker push (ms). The relay can also LISTEN to remove the poll. |

### 3.4 Projections under F

**Required changes**

| Where | Change |
|---|---|
| `apply` blocks | Same `write { }` migration as in C, so applies and receipts commit together. Unmigrated projections need idempotent applies (upserts, or a guard on `aggregate_version`). |
| Batching | `prefetch = N`. Apply up to N messages (or wait up to 50 ms) in one projection DB transaction with their receipts, then `ack(multiple: true)` on the last delivery tag. |
| New projection or rebuild | F-a handover (§3.2.4): declare the queue, backfill from Postgres, consume with receipt deduplication. Needs a runner command: `rebuild(P)` = pause consumer, truncate, backfill, resume. |
| Other persistence layers | Same as in C: receipts or idempotent writes in the target store |
| `init: true` | Replaced by the F-a backfill |

**How behaviour improves**

| Situation | Today | Under F |
|---|---|---|
| Ordering across instances | Broken | Single active consumer per projection queue gives position-ordered applies |
| Projection raises | Dropped for everyone and permanently wrong | Parked: the queue holds subsequent events (the broker buffers them durably) until fixed, then the projection resumes. No data loss. |
| Slow projection | Delays all handlers | Its queue grows. Others are unaffected, and lag is visible as queue depth. |
| New projection | `init` race | Handover backfill. Correct, but more moving parts than C's "start at zero". |
| Rebuild | Manual, racing | Pause, truncate, backfill and resume. Buffered live events are deduplicated by receipt. |
| "Is projection X up to date with event E?" | No | **Not answerable from the broker.** Queue depth is approximate and positions aren't shared, so a read-your-writes wait isn't feasible. |

### 3.5 Infrastructure and platform changes (F)

1. Run LavinMQ (one node for dev and compose, a cluster or a managed CloudAMQP plan in production),
   with credentials, TLS and monitoring. Add it to `docker-compose.yml`, `docker-compose.test.yml`
   and CI.
2. Add the `crystal-es-amqp` and `amqp-client` dependencies. Run topology sync on boot.
3. Server start: start the relay (lock-guarded) and the consumer runner instead of
   `start_queue_listener`.
4. Projections: `write { }` migration. Reactors: same audit as in C.
5. Operations: DLQ and parked-queue runbooks, receipt pruning, alerts on queue depth and unacked age.
6. Cutover: the same constraint as C for reactors. Stop `process_queue`, keep the trigger (it becomes
   the relay's input), and start the relay and consumers. Messages already in the pgmq queue get
   relayed instead of dispatched in-process, so there is **no write pause needed**, which is another
   F advantage. Projections can also be switched one by one (F-a backfill).

### 3.6 Effort (F)

| Phase | Scope | Size |
|---|---|---|
| F1 | `ES::Queue` read access, `EventStore#transaction` (shared with C3), receipts tables | S–M |
| F2 | `crystal-es-amqp`: relay, topology sync, runner, retry, park, DLQ | M |
| F3 | Projection `write` migration, F-a backfill and handover, `rebuild` command | M |
| F4 | Infrastructure (compose, CI, production cluster), operations runbooks, metrics | S–M, plus ongoing operations |

---

## 4. C vs F side by side

| Concern | C: Postgres subscriptions | F: LavinMQ |
|---|---|---|
| New infrastructure | None | A broker in dev, CI and production, operated forever |
| Commit-ordered read | Needs the `xid8` column and watermark (C1) | **Not needed**: the existing pgmq outbox plus a single relay preserves per-aggregate order |
| Single active consumer | Postgres session advisory locks (needs direct connections, not a transaction-pooling PgBouncer) | **Broker-native**, with automatic failover |
| Reactor "once" | Checkpoint in the same transaction, so no receipts table | Receipt in the same transaction plus ack after commit. A receipts table to prune. |
| Projection atomicity | Checkpoint in the projection DB transaction | Receipts in the projection DB transaction |
| Replay, new projection | **Native**: start at zero | Handover backfill from Postgres (F-a) or a duplicated stream (F-b) |
| Rebuild | Reset the checkpoint | Pause, truncate, backfill, deduplicate |
| Cross-handler wait (`await` projection ≥ event) | **Possible** (comparable positions) | Not feasible |
| Poison event | Retry, then `paused`. Operator `skip`. | Retry, then park or DLQ, with a broker UI for inspection and redrive |
| Load on Postgres | Tail reads (one per instance per wake) plus catch-up reads | Relay reads, plus one `fetch_event` per handler per event (or put the stored ciphertext in the message) |
| Monitoring | Built yourself (lag = head − checkpoint) | Mostly free (queue depth, rates, DLQ) |
| Cutover | Projections gradual. **Reactors need a write pause of seconds.** | Gradual, **no write pause** |
| Opens the door to external consumers | Via option I publishers | Built in: other services bind their own queues |
| Total library effort | L (C1–C4) | L (F1–F4), plus operating a broker |

**Reading the table.** C wins on replay and rebuild, on `await` and cross-handler consistency, on
having no extra infrastructure, and on fewer moving parts for projections. F wins on broker-native
failover and monitoring, cutover without a write pause, no `xid8` migration, and being ready for
external consumers. The two share the most expensive piece: the transaction-bound event store plus
the `write { }` projection migration. **Building that first keeps both options open.**

A sensible order, if the choice isn't final:

1. Option A now: a leader lock and retry instead of archive.
2. `EventStore#transaction` (bound store) and the projection `write { }` helper. Both C and F need
   them, and they are useful on their own.
3. Decide between C and F, mainly on whether a broker is wanted for other reasons, such as external
   consumers, ops preference or CloudAMQP availability. If not, C. If yes, F, or C plus an AMQP
   publisher (option I).
