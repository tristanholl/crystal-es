# Event delivery across multiple application instances

Status: research and options, no decision yet. Written against crystal-es 0.11.3 and a production
application built on it, as of 2026-11-24.

This is the single document on the topic. It covers the problem, the shared building blocks, every
option (A–I) with pros, cons, complexity and required changes, in-depth designs of the two leading
options, **C (Postgres catch-up subscriptions)** and **F (LavinMQ/RabbitMQ)**, split by reactors and
projections, and a detailed comparison of the two. That comparison includes the case where running a
broker counts as no cost.

**Contents**

1. Where we are today
2. Requirements
3. Cross-cutting building blocks
4. Options A–I: how they work, pros and cons
5. Required changes per option
6. Comparison matrix
7. Option C in depth: the event store is the stream
8. Option F in depth: LavinMQ (or RabbitMQ)
9. Postgres-only (C) vs LavinMQ (F) in detail, and whether a "free" broker changes the answer
10. Recommended path
11. Open questions

## TL;DR

- **Today:** a trigger fills one pgmq queue, and an in-process `EventBus` fans each message out to
  every handler in sequence. That is correct for one instance. With two or more, instances compete for
  the same queue: per-aggregate ordering is lost, projections apply out of order, `Projection#init`
  races, and one failing handler dead-letters the event for every other handler.
- **The core problem is not transport.** It is:
  - (1) an ordered relay out of the event store,
  - (2) independent progress per handler,
  - (3) exactly one active consumer per handler, or per partition of a handler.

  Every option has to solve all three somewhere.
- **Recommendation: option C**, using the event store itself as the stream through catch-up
  subscriptions in Postgres. The reasons are in §9.5. **This holds even if a LavinMQ/RabbitMQ broker is
  considered welcome or free.** A free broker removes C's infrastructure advantage, but the decisive
  differences remain:
  - **Single delivery path:** projections replay and rebuild through the same path they use live.
    Under F, every rebuild runs a Postgres backfill and then hands over to the queue.
  - **Progress is one position in the same ACID store as the handler's writes.** The checkpoint
    commits in the same transaction. This enables exact lag, `await`, trivial resets and no receipts
    tables.
  - **No delivery state outside Postgres that can be lost or diverge.** LavinMQ's replication confirms
    a publish before the write reaches the followers, see §9.2.
  - **The broker's main operational advantage turns out not to hold.** LavinMQ's single active
    consumer always activates the *first* registered consumer, so work does not spread across
    instances. F needs the same custom assignment logic as C.
- **Where LavinMQ does earn its place:**
  - **jobs and side effects** (queue-shaped work with delays, retries and dead-letter exchanges),
  - **integration events for other services**, through a publisher subscription (option I).

  F is the better choice for event delivery only under specific conditions (§9.5), for example many
  external consumers, a transaction-pooling PgBouncer that can't be bypassed, or no write pause
  possible for the cutover.
- **Do option A now** (one leader instance consumes the existing queue). It is days of work and makes
  multiple instances safe for HTTP immediately.
- **Build the shared foundation next:** a transaction-bound event store and a projection `write` helper.
  Both C and F need them, so the C/F decision can stay open until then.

> Note on "the existing infrastructure component Kafka": the application this was researched against
> runs Postgres as its only infrastructure for events, with no Kafka in its setup. This document
> therefore treats Postgres as the only existing component. If Kafka does run in production outside
> that setup, option E becomes cheaper (see "If Kafka already exists").

---

## 1. Where we are today

### 1.1 The pipeline

```
command handler ──append──▶ eventstore.events (INSERT, BIGSERIAL id)
                                │ AFTER INSERT trigger (same transaction)
                                ▼
                        pgmq "default" queue  (message = event header)
                                │ Queue#listen: read(vt=30s, n=100) every 100ms
                                ▼
              process_queue (the application: the queue initializer)
                fetch_event → materialize → EventBus#publish
                                │ for each subscribed handler, sequentially:
                                ▼
          Reactor#call / Projection#call   (~180 handlers, ~500 routes in the application)
                                │
                  all ok → queue.delete      any raise → queue.archive (no retry)
```

Relevant code:

- `src/adapters/queues/postgres.cr`: the trigger `queue_event_<name>` runs `pgmq.send` inside the
  append transaction. This makes it a correct **transactional outbox**: a message exists if and only
  if the event committed.
- `src/adapters/queues/queue.cr`: `listen` spawns a polling loop into a buffered channel (capacity
  100).
- `src/components/event_bus.cr`: `publish` runs every subscriber synchronously, in subscription order.
- `src/components/projection.cr`: `init` replays into an empty table in a background fiber. There is
  no persisted checkpoint: a projection is either "empty, rebuild" or "assumed live".
- the application `the queue initializer`: a single consumer loop. `delete` runs on success and
  `archive` (dead-letter) on any exception.

### 1.2 What breaks with N instances

| # | Problem | Why |
|---|---------|-----|
| 1 | **Per-aggregate order is lost** | pgmq hands consecutive messages to different instances, so `Accepted` can be projected before `Requested`. Upsert-style projections can then end in the wrong state. |
| 2 | **Duplicate execution on slow handlers** | The visibility timeout is 30 s. A batch of 100 messages handled sequentially can exceed it, and another instance then re-reads and re-runs every handler, reactors included. |
| 3 | **One failure takes the event away from every handler** | Fan-out happens after the dequeue. If reactor 3 of 5 raises, reactors 1–2 already ran, 4–5 never run, and the message is archived with no retry. This already happens with one instance; more instances only make failures more frequent. |
| 4 | **`Projection#init` races** | Every instance sees an empty table and replays into it concurrently. |
| 5 | **Handlers can't be scaled or isolated independently** | A slow projection (search index, a reactor calling a slow API) delays every other handler of the same event. A broken projection blocks reactors. |
| 6 | **No independent rebuild or new-projection backfill** | Without a checkpoint per projection, adding a projection or moving it to another store means `truncate + replay`, racing the live queue. |
| 7 | **`msg_id` / `id` order ≠ commit order** | Both are sequence values taken at INSERT time. A transaction that inserts id 10 can commit after the one that inserted id 11. AGENTS.md already notes that positions aren't commit-ordered. Any design that reads "everything after position X" will **silently skip events**. |

Problems 1–6 are about delivery topology. Problem 7 is about reading the log at all, and it applies to
every option that tails Postgres, including the relay that feeds any broker.

### 1.3 Reactors and projections today

| | Reactors (~125 in the application) | Projections (~55 in the application) |
|---|---|---|
| Purpose | Turn an event into a command (`CommandHandler#handle`). They hydrate aggregates through the injected `@event_store` and sometimes read projections (e.g. `Orders::Reactors::Fulfilment::OnPlaced` calls `Customers::Queries::Customers`). | Fold events into tables in `projections.*`. Each `apply` opens its own `@projection_database.transaction`, and some hydrate aggregates through the default `ES::Config.event_store`. |
| Writes go to | The event store DB (appends), plus the pgmq jobs queue (the jobs database) via `Jobs.enqueue` in command handlers | The projection DB (the projection database) |
| Delivery today | One pgmq message per event. `EventBus#publish` runs every subscriber in subscription order. Any raise archives the message for **all** subscribers. | Same as reactors. `init: true` replays into an empty table in a background fiber. |
| Idempotency today | Mostly domain state checks in the command handlers (`InvalidState`/`Conflict` on a repeat) | Mostly none. `INSERT` on `…Requested` hits a unique index on a repeat and raises. |
| Implicit coupling | Runs in the same loop as projections, so it usually sees projections that are "fresh enough" | Shares a failure fate with every reactor subscribed to the same event |

The last row matters. **Every option that runs handlers independently removes the implicit
coupling.** Projections can lag reactors and the other way round. Reactors that read projections must
tolerate that, or wait explicitly (C can offer an explicit wait; F cannot, see §7.4 and §8.4).

---

## 2. Requirements

| ID | Requirement |
|----|-------------|
| R1 | Run N identical instances. Any instance can die at any time without losing or permanently stalling events. |
| R2 | **Reactors execute once**: at least once delivery, plus deduplication so that a reactor's *state effects* (events it appends) happen exactly once. External side effects (mail, HTTP, third-party APIs) can only be at-least-once with idempotency keys; that is a law of distributed systems, not a library limitation. |
| R3 | **Projections are independent**: each has its own checkpoint, pace, error state and persistence layer (projection DB, another Postgres, a search index, object storage, …). |
| R4 | Per-aggregate (or per-tag) ordering for every handler. |
| R5 | Add, rebuild or move a projection without downtime and without touching the others. |
| R6 | Failure isolation: a poison event stops one handler (or one partition), with retries, backoff and visibility. |
| R7 | Efficiency: no O(handlers) write amplification per event, and no hot polling of the events table by ~180 loops. |
| R8 | Library constraints (AGENTS.md): additive and backward-compatible, `setup` idempotent on existing stores, in-memory adapter parity, no environment reads and no extension creation by the library. |

---

## 3. Cross-cutting building blocks

These recur across the options, so they are described once.

### 3.1 A safe, commit-ordered read position (solves problem 7)

There are three known approaches:

1. **Transaction-id watermark (recommended).** Add `transaction_id xid8 DEFAULT pg_current_xact_id()`
   to `eventstore.events`. Readers fetch only rows from transactions that are older than every running
   transaction:

   ```sql
   SELECT id, transaction_id, header, body
     FROM eventstore.events
    WHERE (transaction_id, id) > ($last_tx, $last_id)
      AND transaction_id < pg_snapshot_xmin(pg_current_snapshot())
    ORDER BY transaction_id, id
    LIMIT $batch;
   ```

   Every transaction with an xid below the snapshot's `xmin` has finished, and no new transaction can
   ever get an xid below it. A `(transaction_id, id)` checkpoint therefore never skips a row.
   - The checkpoint **must be the pair**, not `id` alone. A transaction can take its xid early (for
     example in the `tag_versions` upsert) and insert its event row after a later transaction did. In
     that case, ordering by `id` with an xmin filter can still skip a row.
   - Causal order is preserved: a command that read event E before appending gets its xid after E's
     transaction committed, so its events sort after E. Per-aggregate order follows, because the
     `(aggregate_id, aggregate_version)` unique index forces version n+1 to be written after version n
     was read.
   - `xid8` is 64-bit and epoch-extended (PG 13+), so wraparound is not an issue. The crystal-es test
     setup runs Postgres 18.
   - Cost: any long-running writing transaction anywhere in the cluster holds `xmin` back and delays
     delivery (it never loses events). Keep transactions short and alert on `xmin` age.
   - Migration that respects the append-only invariant: `ADD COLUMN transaction_id xid8` (nullable,
     with no rewrite), then `ALTER COLUMN … SET DEFAULT pg_current_xact_id()`. **No backfill
     `UPDATE`.** Historical rows stay NULL and sort first via
     `COALESCE(transaction_id, '0'::xid8)`. Back it with an expression index
     `(COALESCE(transaction_id,'0'), id)`, built `CONCURRENTLY` like `build_missing_indexes` already
     does, and applied in `setup`'s early-return branch.
2. **Serialize appends.** Take `pg_advisory_xact_lock(<global>)` in `append_batch`, so that `id`
   order equals commit order. This is trivial to build, but it caps write throughput at one append
   transaction at a time and turns the decision-consistency design (DCB tag locks) into a global lock.
3. **Gap detection with timeout** (Marten's "high water mark"). Read by `id`. When a gap appears,
   wait up to T for it to fill, then skip it as a rolled-back sequence value. This is heuristic: a
   transaction slower than T loses events. It contradicts "fail loudly".

### 3.2 Subscriptions and checkpoints (solves problems 3, 5, 6 and R3, R5, R6)

A **subscription** is a named consumer of the log, such as `projection:Orders::Projections::Orders@<fingerprint>`
or `reactor:Customers::Reactors::Onboarding::OnVerified`. It has:

- a checkpoint `(transaction_id, id)`,
- a status (`running`, `failing`, `paused`, `rebuilding`), `retry_count`, `last_error` and
  `last_failed_event_id`,
- an event filter, derived from the existing routes (`EventBus#routes` and `handles?`). The reader can
  then use the existing `event_handle` index and skip irrelevant rows. **The checkpoint still advances
  to the end of the scanned window**, so a quiet subscription doesn't re-scan.

Checkpoint location decides the delivery guarantee:

| Handler writes to | Checkpoint stored | Guarantee |
|---|---|---|
| Same DB as the event store (reactors) | `eventstore.subscriptions`, same transaction as the appends | **Effectively-once** |
| Projection DB (another Postgres) | A checkpoint table in *that* DB, same transaction as the projection writes | **Effectively-once** |
| Non-transactional store (search index, S3, ClickHouse) | Kept with the data, or separately after the write | At-least-once plus idempotent writes keyed by `event_id` or position |

A side benefit is **batched projection commits**: apply 500 events and the checkpoint in one
transaction instead of one implicit transaction per event. This is usually an order-of-magnitude
speed-up for rebuilds.

### 3.3 Single active consumer (solves problems 1, 2, 4)

Each subscription (or partition, see 3.5) must have exactly one consumer at a time:

- **Session advisory lock (recommended):** `pg_try_advisory_lock(hash(subscription))` on a dedicated
  connection. If the instance dies, the connection drops and the lock is released, which gives
  automatic failover in seconds. It holds **no transaction open**, which matters because of the `xmin`
  issue in 3.1. The library already uses this pattern in `with_setup_lock`. Caveat: it is incompatible
  with transaction-mode PgBouncer, so a direct connection is needed for the lock holder.
- **Lease row:** `lease_owner` / `lease_expires_at` with a heartbeat `UPDATE`. It works through
  poolers, but needs fencing (checkpoint writes must check `lease_owner`) and has a failover delay of
  one lease period.
- **Don't** hold `SELECT … FOR UPDATE` on the subscription row for the lifetime of the consumer. That
  is a long transaction and freezes `xmin` for every subscription.

Distribution: each instance tries to lock every subscription and partition it knows. A simple
"try-lock, back off, retry every k seconds" loop spreads them across instances. A smarter one caps
`locks_per_instance ≈ ceil(total / live_instances)`, using a heartbeat table, to rebalance on
scale-out.

### 3.4 Reactor "execute once"

Delivery is at-least-once in every option, including Kafka. "Once" is enforced at the handler. There
are three layers, strongest first:

1. **Transactional inbox (recommended).** The dispatcher opens a transaction and gives the reactor a
   *transaction-bound* `ES::EventStore`. Reactors already receive `event_store:` through the
   constructor, so this needs **no reactor code change**. Inside that transaction it:
   - runs the reactor (its hydrations read through the same connection, and its command handlers
     append through it),
   - advances the reactor's checkpoint, or inserts `(reactor, event_id)` into
     `eventstore.reactor_receipts` when consumers are partitioned or competing,
   - commits.

   A redelivery then finds the checkpoint or receipt and skips. A crash before commit leaves nothing
   behind. **Library change:** `append_batch` currently opens its own `@db.transaction`. It needs a
   variant that joins an outer connection, for example `EventStore#within(connection) : EventStore`,
   or a fiber-local "current transaction". This is the main new public API.
2. **Causation metadata.** Add `causation_id` and `correlation_id` to `ES::Event::Header`, defaulting
   to nil and omitted from the JSON when empty to keep old JSON byte-identical. This makes duplicates
   detectable and traceable, and enables a unique index such as `(causation_id, command_handler)`
   where it makes sense. It is valuable for observability regardless of the option chosen.
3. **Domain idempotency.** The command handler rejects "accept an already accepted API key" with
   `InvalidState` or `Conflict`. The application this was researched against relies on this today. It is fragile as the only guard, but a
   good second line.

External side effects stay at-least-once. Applications should route them through `Jobs.enqueue` from
command handlers, which is the right shape. If `Jobs.enqueue` writes to a separate jobs database, it is outside the append transaction. If that is the same database, the enqueue can join the reactor
transaction too (a job outbox). Otherwise an append can succeed while the enqueue fails, or the
reverse.

### 3.5 Partitioning (scaling one handler beyond one consumer)

To parallelize a single hot subscription while keeping per-aggregate order, split it into P partitions
by `hash(aggregate_id) % P`, or by the first tag for DCB-style events. Each partition has its own
checkpoint and lock. P is fixed per subscription; changing it means a new subscription name and a
replay, as in Kafka. Most projections need P = 1. Only a few reactors or heavy projections need more.
Store a computed `partition_key smallint` column, or filter on an expression index, so that P
partitions don't each re-scan everything.

### 3.6 Avoiding hot polling (R7)

- **LISTEN/NOTIFY wake-up.** An `AFTER INSERT … FOR EACH STATEMENT` trigger calls
  `pg_notify('crystal_es_events', '')`. Notifications are transactional (delivered on commit) and
  deduplicated within a transaction. Each instance keeps one `PG.connect_listen` connection and wakes
  its consumers. There is also a fallback poll every few seconds, because NOTIFY is a hint, not a
  guarantee.
- **Shared tail reader.** Per instance, one fiber reads the live tail once and fans the rows out in
  memory to every caught-up subscription it holds. Only lagging or rebuilding subscriptions read on
  their own. With ~180 subscriptions, this reduces live-tail queries from ~180 per wake-up to about 1 per
  instance.

---

## 4. Options

Complexity scale: **S** ≈ days, **M** ≈ 1–3 weeks, **L** ≈ 1–2 months, **XL** ≈ more, or ongoing
operational burden. The estimates cover library and platform work for one engineer familiar with the
codebase.

### A. Single active dispatcher (leader election on today's pipeline)

**How:** Only the instance holding `pg_try_advisory_lock('crystal_es_dispatcher')` runs
`process_queue` and `Projection#init`. The others serve HTTP and keep retrying the lock.

**Pros**
- Smallest possible change. No schema changes, no API break. It can ship as an `ES::Queue` helper or
  live purely in the platform.
- Fixes problems 1, 2 and 4 immediately. Sequential consumption keeps ordering as good as it is today.
- Lets you scale HTTP horizontally now.

**Cons**
- Event processing does not scale. One instance does all the work.
- Problems 3, 5, 6 and 7 remain: fan-out failures, no per-handler isolation, no checkpoints, and
  `msg_id` is still not commit-ordered. With a single consumer, problem 7 only reorders events and
  does not skip them, because pgmq delivers every message eventually.
- Failover leaves in-flight messages invisible until their visibility timeout expires.

**Complexity: S.** Recommended as step 0 regardless of the final choice.

### B. pgmq fan-out: one queue per subscriber

**How:** The trigger, or a router, sends each event to one pgmq queue per subscribed handler (~180 in
the application, filtered by route). Each queue has its own consumer, retries and archive, and an advisory lock
gives it a single active consumer.

**Pros**
- Reuses pgmq and the existing `ES::Queue` abstraction. Familiar semantics.
- Per-handler failure isolation and retries (fixes problems 3 and 5).
- Partly an incremental evolution of today's code.

**Cons**
- **Write amplification:** about routes/|event types| extra rows per event, plus pgmq archive and vacuum
  churn across ~180 tables. This is the opposite of R7.
- Queues are not logs. There is **no replay**: a new or rebuilt projection must backfill from the
  event store and then hand over to its queue, which raises a deduplication and race problem
  (problem 6 is not solved).
- Ordering requires one consumer per queue. Competing consumers lose order; pgmq has no
  partition-by-key read in general use (check the installed version's FIFO or grouped-read support
  before relying on it).
- Visibility-timeout semantics don't fit long handlers, and a heartbeat (`set_vt`) is needed.
- Effectively-once still needs the transactional inbox from 3.4. pgmq lives in the same DB, so
  `delete` can join the transaction, which is a plus.
- msg_id ordering is still not commit-ordered (problem 7) across queues.

**Complexity: M.** Viable, but it is option C with more writes and without replay.

### C. Event store as the stream: Postgres catch-up subscriptions (recommended)

**How:** Combine 3.1 (`xid8` watermark), 3.2 (subscription checkpoints), 3.3 (advisory-lock single
consumer), 3.4 (transactional reactor inbox), 3.5 (optional partitions) and 3.6 (NOTIFY plus a shared
tail reader). The pgmq trigger is no longer needed for event delivery.

This is the model used by Marten's async daemon, Eventuous, Emmett, Commanded and Axon's tracking
processors. It is the standard answer when the store is Postgres.

```
instance 1                          instance 2
┌──────────────────────────┐        ┌──────────────────────────┐
│ LISTEN crystal_es_events │        │ LISTEN crystal_es_events │
│ tail reader (1 query)    │        │ tail reader (1 query)    │
│  ├─ proj:Customers  🔒 │        │  ├─ proj:Orders      🔒 │
│  ├─ proj:Invoices    🔒 │        │  ├─ reactor:Onboarding🔒 │
│  └─ reactor:Billing#0 🔒│        │  └─ reactor:Billing#1 🔒│  (partitioned reactor)
└──────────────────────────┘        └──────────────────────────┘
        ▲ reads WHERE (tx,id) > checkpoint AND tx < snapshot_xmin
        │
  eventstore.events  +  eventstore.subscriptions  +  eventstore.reactor_receipts
```

**Pros**
- **No new infrastructure.** Postgres only, which matches the library's "optimized for PostgreSQL"
  positioning and the application's self-hosting stance.
- Fixes every problem in the table above. Per-aggregate ordering, per-handler isolation, retries and
  pause, and effectively-once reactors and same-DB projections.
- **Replay and new projections come for free:** a subscription starting from `(0,0)` *is* the
  backfill. There is no separate `init` path and no handover race. A rebuild after a projection schema
  change (fingerprint) becomes blue/green: subscribe `…@<new fingerprint>` into a new table, catch up,
  swap, then drop the old one. This fits the "projection schemas are immutable" invariant well.
- Projections can target any persistence layer through the checkpoint placement rules in 3.2.
- Zero write amplification. The only extra write is one checkpoint update per batch per subscription.
- Testable with the in-memory adapter (a global array plus a mutex gives a trivially safe watermark),
  so adapter parity is natural.
- It becomes the foundation for option I: a broker publisher is "just another subscription".

**Cons**
- **Read load on the events table** grows with the number of subscriptions that are catching up.
  Live-tail cost is mitigated by the shared reader and NOTIFY. Rebuilds of large projections should be
  throttled.
- **The `xmin` coupling:** a long writing transaction anywhere delays all delivery. This needs
  monitoring and statement timeouts.
- **Session advisory locks need direct connections**, not a transaction-pooling PgBouncer.
- Throughput per subscription partition is bounded by one consumer. Partitioning (3.5) scales it,
  but P is fixed.
- More library surface to design and get right: the transaction-joining event store, lease and
  rebalance, retry and poison handling, and an operations API (`pause`, `reset`, `lag`). AGENTS.md
  requires "fail-loudly" specs that prove the locks can fail.
- Cross-database projections only get effectively-once if they store their checkpoint in their own
  DB. Otherwise they need idempotent writes.

**Complexity: L** overall, but it is incremental, and each phase ships on its own (see section 6).

### D. Postgres logical replication / CDC read directly by the app

**How:** Create a logical replication slot (`pgoutput` or `wal2json`) on `eventstore.events`. One
reader per instance, or one leader, decodes committed inserts in **true commit order** and dispatches
them to subscriptions. Checkpoints are kept as in C.

**Pros**
- Native commit order with no `xid8` column or watermark, so no `xmin` coupling.
- Lowest latency and no polling at all.

**Cons**
- **crystal-pg does not implement the streaming replication protocol** as far as we know. You would
  have to build CopyBoth handling plus pgoutput decoding, or shell out to `pg_recvlogical`. That is a
  substantial and subtle piece of code.
- **Slot operations:** an inactive slot retains WAL without bound and can fill the disk. It needs
  `max_slot_wal_keep_size`, monitoring, and a slot-ownership story across instances, since a slot
  allows one active reader.
- It doesn't give replay. A slot starts "now", so backfill still reads the table and you still need
  C's checkpointing.
- Needs `wal_level=logical` and the `REPLICATION` privilege, which the library can't set up. That is
  fine under AGENTS.md (no extension creation) but adds deployment steps.

**Complexity: XL.** Only worth it if latency or polling cost becomes a measured problem after C. It
then replaces C's reader only, not the subscription model.

### E. Kafka (or Redpanda)

**How:** A relay publishes each event to a topic, keyed by `aggregate_id` so that ordering holds per
partition. Every projection or reactor is its own **consumer group**, so groups are independent,
partitions are spread across instances, and rebalancing is automatic. The relay is either:
- **E1:** an in-app outbox relay. This is a subscription from option C that produces to Kafka with an
  idempotent producer. It needs C's watermark (3.1) anyway.
- **E2:** Debezium on `eventstore.events` (logical decoding, commit-ordered). It needs Kafka Connect
  and a replication slot (see D's operational cons).

Consumers store offsets **in the projection DB inside the projection transaction** for effectively-once
projections. Reactors use the inbox (3.4). Kafka's exactly-once transactions only cover
Kafka→Kafka pipelines and don't help a reactor that writes to Postgres.

**Pros**
- Mature model for exactly this problem: consumer groups, partitions, rebalancing, lag metrics and
  retention-based replay.
- Scales far beyond Postgres tailing. It is the natural choice if **other services** (analytics, a
  data platform, other teams) need to consume domain events.
- Decouples read load from the primary database.

**Cons**
- **New, heavy infrastructure** (brokers, KRaft, monitoring, upgrades) for a platform that runs on
  Postgres alone today. Redpanda is lighter to run but still a cluster.
- **It doesn't remove the hard part:** the relay still needs a commit-ordered read of Postgres (3.1 or
  Debezium). The event store remains the source of truth, so Kafka is a second copy that must not
  diverge (retention, re-publishing after a restore).
- **Crystal client risk:** no widely used, maintained native Kafka client is known to us. You would
  likely need FFI bindings to librdkafka and to maintain them yourself. Verify before committing.
- Replay depends on retention. Infinite retention duplicates the store. Otherwise, rebuilds read from
  Postgres anyway, which means building C's backfill path regardless.
- Partition count is fixed per topic. Re-partitioning breaks key ordering during the transition.
- Dev and test environment complexity (compose and CI services). The library needs a new adapter
  family with no in-memory equivalent that has the same semantics.

**Could Kafka be the event store itself?** No. crystal-es relies on conditional appends: per-aggregate
version uniqueness and DCB tag-version checks under row locks, plus `read(query)` by tags. Kafka has
no per-key optimistic concurrency or secondary indexes, so these guarantees would be lost.

**If Kafka already exists** in the production estate, E1 is the cheapest way to add it: build option C
first, then add a Kafka publisher subscription (option I) for consumers outside this application. Do
not move internal projections and reactors onto it unless there is a measured throughput reason.

**Complexity: XL** without existing Kafka. With an existing cluster, about **L**, dominated by the
client bindings and the relay.

### F. RabbitMQ / LavinMQ (AMQP)

**How:** A relay publishes to a topic exchange (`routing_key = event_handle`). Each subscriber gets a
durable queue, and the **bindings are generated from `EventBus#routes`**, which maps very naturally to
today's wiring. Single-active-consumer per queue gives ordering. A consistent-hash exchange can
partition hot subscribers by `aggregate_id`. Streams (RabbitMQ Streams, or LavinMQ stream queues)
offer an offset-based log for replay.

**Pros**
- **LavinMQ is written in Crystal**, and 84codes maintains `amqp-client.cr`. This is the best client
  story of all the brokers.
- Lighter to run than Kafka. Built-in dead-letter exchanges, TTL-based retries, per-queue metrics and
  a management UI.
- Routing by event type happens in the broker, so there is no read amplification.

**Cons**
- New infrastructure, and a relay out of Postgres. The relay can reuse today's pgmq outbox with a
  single active relay instance, which preserves per-aggregate order without 3.1.
- Classic queues have no replay. Backfill comes from Postgres, followed by a handover to the queue, the
  same race as in B. Streams fix this, but they are a different consumer model: client-tracked
  offsets, similar to Kafka.
- Ordering requires single-active-consumer or a consistent-hash partition per queue. LavinMQ supports
  both natively, without a plugin (RabbitMQ needs a plugin for consistent hashing). But single active
  consumer always activates the first registered consumer, so spreading work across instances is
  app-side logic (§8.1). Streams support offsets and filtering, but not single active consumer.
- In clustered mode, a publisher confirm doesn't guarantee replication, so a leader failover can lose
  confirmed messages (§8.2.1).
- The same at-least-once and inbox story as everything else. ~180 queues to manage (automated from
  routes).

**Complexity: L** (relay, topology management, backfill handover, adapter, local dev and CI).

### G. AWS SNS FIFO → SQS FIFO

**How:** The relay publishes to an SNS FIFO topic with `MessageGroupId = aggregate_id` and
`MessageDeduplicationId = event_id`. Each subscriber has an SQS FIFO queue with a filter policy by
`event_handle`. Parallelism comes across groups, with order within a group.

**Pros**
- Fully managed, with no brokers to run. Per-aggregate ordering with parallelism by group comes
  built-in.
- DLQs and redrive are built-in. SNS FIFO also offers message archive and replay.

**Cons**
- AWS lock-in. A self-hosted stack (Postgres, S3-compatible object storage) contradicts this, as does the current
  direction. Local dev needs LocalStack.
- The deduplication window is 5 minutes, so it is not a substitute for the inbox. FIFO throughput
  quotas apply, and costs are per request.
- The Crystal AWS SDK story is thin (request signing exists, higher-level clients largely don't).
- Higher latency (tens to hundreds of ms), and still a relay out of Postgres (pgmq outbox or 3.1).

**Complexity: L**, plus ongoing cloud coupling. Not recommended for this platform.

### H. Lightweight log brokers: NATS JetStream, Redis/Valkey Streams

**NATS JetStream:** one stream `events.>` with subjects `events.<aggregate_type>.<handle>`, a durable
pull consumer per subscriber, `Nats-Msg-Id = event_id` for publish deduplication, and replay from any
sequence.
- Pros: a single small binary with a log, durable consumers, ack/redelivery and replay. It is the
  closest broker equivalent to option C. A community Crystal client exists (maturity of its JetStream
  support should be verified).
- Cons: new infrastructure and a relay out of Postgres (pgmq outbox or 3.1). Ordering per aggregate requires
  `max_ack_pending = 1` per consumer or subject-based partitioning. The ecosystem is smaller than
  Kafka's.
- **Complexity: L.**

**Redis/Valkey Streams:** `XADD` with a consumer group per subscriber, `XACK`, and `XAUTOCLAIM` for
crashed consumers.
- Pros: simple, fast and well known. Mature Crystal Redis clients exist.
- Cons: memory-bound retention, so it is no long-term replay. Persistence depends on AOF settings.
  There is no per-key ordering within a group without manual partitioning. It is new infrastructure
  that brings little C doesn't.
- **Complexity: M–L.** Not recommended.

### I. Hybrid: C inside, pluggable publishers outside

**How:** Build option C as the internal delivery mechanism. Define an `ES::Publisher` adapter
interface (Kafka, NATS, AMQP and SNS implementations live in separate shards). A publisher runs as
**one more subscription** that relays events, possibly only "integration events", to an external
broker with the event's `event_id` as the idempotency key.

**Pros**
- Internal correctness (ordering, effectively-once and rebuilds) never depends on a broker.
- The broker choice becomes a deployment decision per consumer, not an architectural one. Adding Kafka
  later is a contained adapter.
- Keeps the core library dependency-free.

**Cons**
- Two delivery paths to understand. External consumers get at-least-once delivery and must deduplicate
  by `event_id`.

**Complexity:** C plus **M** per publisher adapter.


---

## 5. Required changes per option

Each list is complete enough to estimate, but not a design. C and F follow in full in §7 and §8.

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
| Reactors | A transactional inbox: `pgmq.delete` plus the reactor's appends in one transaction. pgmq is in the same DB, so this is possible if the jobs database equals the event store database. The event store needs to join an outer transaction (as in C, §7.2.4). **Benefit:** per-reactor isolation and retries. |
| Projections | Idempotent writes or a receipt per event. Backfill for new or rebuilt projections must come from `each_event` with a handover to the queue (deduplicate by `event_id`). **Benefit:** isolation. **Cost:** no native replay. |
| Limits | One message per event per subscriber. Ordering only with a single consumer per queue. |

### C. Postgres catch-up subscriptions (recommended). Full design in §7.

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
| Reactors | Inbox: `(reactor, event_id)` receipt in the event store transaction (as in F, §8.3). **Benefit:** scale by partitions, broker-managed rebalancing. |
| Projections | Offset or position checkpoint in the projection DB transaction. Rebuild: replay from Postgres (`read_all`), or from Kafka if retention is infinite. **Benefit:** consumer lag tooling, and external consumers can use the same topic. |

### F. RabbitMQ / LavinMQ. Full design in §8.

| Area | Summary |
|---|---|
| Library | A relay from the existing pgmq outbox to the broker, topology generated from routes, a consumer runner on `amqp-client.cr`, an inbox and receipts, and a transaction-bound event store |
| Platform | Relay plus consumers, DLQ handling, cutover |
| Infra | A LavinMQ (or RabbitMQ) node or cluster |

### G. SNS FIFO → SQS FIFO

| Area | Changes |
|---|---|
| Library | A new shard with an SNS publisher relay (`MessageGroupId = aggregate_id`, `MessageDeduplicationId = event_id`) driven by the pgmq outbox relay (§8.2.1) or `read_all`, and an SQS long-poll consumer runner. SigV4-signed HTTP calls, because no full Crystal AWS SDK is available. The inbox is the same as in F. |
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

## 6. Comparison matrix

| | A Leader | B pgmq fan-out | **C PG subscriptions** | D Logical repl. | E Kafka | F Rabbit/LavinMQ | G SNS/SQS | H NATS JS |
|---|---|---|---|---|---|---|---|---|
| New infrastructure | none | none | **none** | config only | cluster | broker | AWS | broker |
| Processing scales horizontally | ✗ | per handler | per handler and partition | per handler | per partition | per queue and partition | per group | per consumer |
| Per-aggregate order | ✓ (1 consumer) | needs SAC | ✓ | ✓ | ✓ (key) | needs SAC/hash | ✓ (group) | needs config |
| Handler isolation and retries | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Replay and new projection backfill | ✗ | ✗ (handover race) | **✓ native** | ✗ (needs C) | retention-bound | streams only | archive (limited) | ✓ |
| Effectively-once reactors | ✗ | with inbox | **✓ (same-tx checkpoint)** | with inbox | with inbox | with inbox | with inbox | with inbox |
| Projections in other stores | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Write amplification | none | high (×subscribers) | none | none | ×1 (copy) | ×subscribers | ×subscribers | ×1 |
| Still needs commit-ordered read (3.1) | no* | yes | yes | no (native) | relay: pgmq outbox, 3.1 or Debezium | no (pgmq outbox relay) | no (pgmq outbox relay) | no (pgmq outbox relay) |
| Crystal client maturity | n/a | ✓ | ✓ | ✗ (build it) | ✗ (FFI) | **✓ (84codes)** | thin | community |
| In-memory adapter parity | ✓ | ✓ | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ |
| Complexity | **S** | M | **L (phased)** | XL | XL (L if present) | L | L | L |

\* A has a single sequential consumer reading pgmq, which redelivers everything eventually. It
reorders events but does not skip them.

---

## 7. Option C in depth: the event store is the stream

### 7.1 Target behaviour

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

### 7.2 Library changes (crystal-es)

#### 7.2.1 Schema: event store database (applied in `setup`, including the existing-store branch)

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

#### 7.2.2 Reading the log

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

- Postgres: the watermark query from §3.1. `handles` adds
  `header->>'event_handle' = ANY($n)`. The result also reports the last position *scanned*, so a
  filtered subscription advances past events it ignores.
- In-memory: `transaction_id = 0`, `id = array index`. Appends are atomic under the store's mutex, so
  every stored event is immediately safe. Shared specs prove parity.
- `ES::EventStore::Event` gains a `position : Position?` getter (nil where unknown). This is additive.
- `each_event` and `last_event_id` stay as they are, so existing callers are unaffected.

#### 7.2.3 Runner, locks, checkpoints

New files under `src/components/subscriptions/`:

| Type | Responsibility |
|---|---|
| `ES::Subscription` (abstract) | `name`, `handles : Array(String)`, `partitions : Int32`, `batch_size`, `checkpoint_store`, `process(batch, partition)` |
| `ES::ReactorSubscription(R)` | One event per transaction: reactor call plus checkpoint in the event store transaction (§7.3) |
| `ES::ProjectionSubscription(P)` | N events per transaction: applies plus checkpoint in the projection DB transaction (§7.4) |
| `ES::CheckpointStore` (abstract) + `Postgres` / `InMemory` | `load(name) : Position`, `save(connection, name, position)`, `fail(name, event_id, error)`, `reset(name)` |
| `ES::Subscriptions::LockManager` | One **dedicated session connection** per instance. `pg_try_advisory_lock(hashtext(name))` per subscription or partition. A periodic acquire loop (with a cap per instance for spread) and release on shutdown. Advisory locks are session-scoped and hold no transaction open, so they don't hold back `xmin`. |
| `ES::Subscriptions::TailReader` | Wakes on NOTIFY (`PG.connect_listen`) or on a fallback poll (for example every 2 s). Reads one batch after the minimum checkpoint of its caught-up subscriptions and fans it out in memory. Lagging subscriptions get their own catch-up fiber until they reach `head`. |
| `ES::Subscriptions::Runner` | Builds subscriptions from `EventBus#routes`, applies per-subscription settings (partitions, batch size, retry policy), starts and stops (graceful: finish the current batch, release the locks), exposes `status`/`lag`. |

Failure policy, the same for both handler types: on a raise, roll back the transaction. Set the
subscription status to `failing` with `attempts`, `failed_event_id` and `last_error`, back off
exponentially, and retry **the same event**. Order is never broken by skipping. After N attempts it
moves to `paused`, which needs an operator to `resume` or `skip(event_id)`. The skip is explicit and
logged. Only that subscription (or partition) stops. Everything else continues.

#### 7.2.4 Transaction-bound event store (needed by reactors, and reused by F, B and E)

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

#### 7.2.5 Projection changes

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

#### 7.2.6 What stays and what's deprecated

- `ES::EventBus` stays: it is the routing table, and `publish` stays for specs and for applications
  without a runner.
- The `ES::Queue` adapters stay (they are a public base class), but the `queue_event_<name>` trigger
  is no longer needed for delivery. Add `ES::QueueAdapters::Postgres#teardown_trigger` for the
  cutover. Deprecate in the CHANGELOG.
- This is a minor version bump, with upgrade notes: migration, index build time, the cutover
  procedure, `pg_monitor` grants on the new tables, and the need for a direct connection for locks.

### 7.3 Reactors under C

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

### 7.4 Projections under C

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

### 7.5 Application changes

1. Server start-up: replace `start_queue_listener` with `start_subscriptions`. Build the runner
   from `ES::Config.event_bus`, a direct (unpooled) connection for locks, a LISTEN connection, and
   per-subscription settings (a subscriptions initializer).
2. Migrate the projections to `write { }` (mechanical, any order).
3. Audit reactors: the injected store is passed everywhere, and reactors that read projections are
   reviewed (§7.3).
4. Jobs: decide whether the jobs database is the event store database. If it is, add a transactional
   `enqueue`.
5. Operations: a `subscriptions status|pause|resume|skip|rebuild` CLI, lag and `xmin`-age
   metrics, and `statement_timeout`/`idle_in_transaction_session_timeout` on application roles.
6. Specs: keep `ES::Config.event_bus.publish` for unit specs. Add an integration spec that runs the
   runner against the in-memory store.

### 7.6 Cutover (once, per environment)

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

### 7.7 Effort (C)

| Phase | Scope | Size |
|---|---|---|
| C1 | `xid8` column and index, `Position`, `read_all`/`head`, in-memory parity, shared specs | S–M |
| C2 | `CheckpointStore`, `LockManager`, `TailReader`, `Runner`, failure policy, projection `write` helper; projections migrate one at a time | M |
| C3 | `EventStore#transaction` (bound store), `ReactorSubscription`, partitions, `await`, reactor cutover | M |
| C4 | Operations CLI, metrics, blue/green rebuild (optional) | S–M |


---

## 8. Option F in depth: LavinMQ (or RabbitMQ)

LavinMQ features this design relies on, verified against its documentation:
[single active consumer](https://lavinmq.com/documentation/single-active-consumer) on queues (not on
streams), a native [consistent-hash exchange](https://www.lavinmq.com/documentation/consistent-hash-exchange)
that can hash on a header and needs no plugin (RabbitMQ needs one), and
[stream queues](https://lavinmq.com/documentation/streams) with
[server-side offset tracking and filtering](https://lavinmq.com/documentation/server-side-offset-tracking-and-stream-filtering).
LavinMQ is written in Crystal, and 84codes maintains the Crystal client `amqp-client.cr`.

### 8.1 Target behaviour

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

- Each handler gets a durable queue with `x-single-active-consumer: true`. The broker activates one
  consumer and fails over to the next on disconnect, keeping order.
- **Work distribution is not automatic.** LavinMQ activates the *first registered* consumer, fails
  over in connection order, and disables consumer priorities on single-active-consumer queues. If every
  instance subscribes to every queue, the first instance to boot runs every handler. The runner
  therefore needs app-side assignment:
  - each instance consumes only its share of the queues (rendezvous hashing over a membership table
    with heartbeats), and re-subscribes when membership changes; or
  - it uses exclusive consumers as a lock, trying `basic.consume(exclusive: true)` per queue under a
    per-instance cap. This is the same pattern as C's try-lock, and therefore the same effort.
- Bindings are generated from `EventBus#routes`: queue `es.<kind>.<Class>` is bound to `es.events`
  once per event handle it handles.
- Hot handlers get a per-handler consistent-hash exchange (bound to `es.events` for the same handles),
  hashing on the `aggregate_id` header, with P single-active-consumer queues behind it. This gives
  per-aggregate order and P-way parallelism.

### 8.2 Library changes

Core crystal-es changes are small. The broker code goes into a separate shard, `crystal-es-amqp`, so
the core stays dependency-free (option I).

#### 8.2.1 The relay: reuse the existing outbox

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
- **Broker durability gap.** In a LavinMQ cluster, the leader confirms a publish once it is written to
  the page cache and queued for replication, not once followers have it. A leader failure right after
  the confirm can lose messages whose outbox rows the relay has already deleted. Mitigations:
  - `archive` instead of `delete` (pgmq keeps the row), and keep archived rows for a retention window.
  - A reconciliation job that compares handler receipts with the events of the last window and
    re-relays gaps. Receipts make re-relaying safe.

  This is extra machinery that C doesn't need, because in C the delivery state *is* the event store.
- The payload is **the header only**, as today. Consumers fetch the stored event (`fetch_event` by
  `event_id`, an indexed lookup), so bodies, including encrypted ones and personal data, never enter
  the broker. That is consistent with the AGENTS.md rules on secrets and personal data. The cost is
  one primary-key read per handler per event.
- Core change: `ES::Queue` needs a public `read` (it is `protected` in the Postgres adapter today) or
  a `drain(&)` helper. This is additive.

#### 8.2.2 Topology management

`ES::AMQP::Topology.sync(bus : EventBus, partitions : Hash(Class, Int32))` declares the exchange,
queues (`x-single-active-consumer`, `x-dead-letter-exchange: es.dlx`, `x-queue-type` classic or
quorum on RabbitMQ), consistent-hash exchanges and bindings, and removes bindings for routes that no
longer exist. It runs on every boot and is idempotent, which fits the `setup` philosophy.

Changing P for a handler means a new set of queues: drain the old ones first, the same as changing
Kafka partitions.

#### 8.2.3 Consumer runner and inbox

- `ES::AMQP::Runner` subscribes to every handler queue with manual acks and `prefetch` (1 for
  reactors, N for projections). It acks **only after the database transaction commits**.
- Deduplication receipts, because broker delivery is at-least-once:
  - reactors: `eventstore.reactor_receipts (handler TEXT, event_id UUID, processed_at TIMESTAMPTZ, PRIMARY KEY (handler, event_id))`
    in the event store database,
  - projections: the same table shape in the projection database (`_crystal_es_projection_receipts`).
  - Pruning: delete receipts older than the maximum redelivery horizon (for example 14 days, to cover
    manual DLQ redrives). Redriving older messages must be refused, which the runner checks against
    `event.created_at`.
- **Core change shared with C:** `ES::EventStore#transaction` (the bound store, §7.2.4), so a reactor's
  appends and its receipt commit together.
- Retry policy. Ordering and dead-lettering conflict:
  - in-process retries with backoff first (the message stays unacked, so the single active consumer
    keeps the queue blocked and order holds),
  - then either **park**: stop consuming that queue and alert (order preserved, recommended for
    projections and most reactors), or **dead-letter** with `basic.reject` (the queue continues, but
    later events of the same aggregate overtake the failed one, acceptable only for reactors marked
    `order_insensitive`).

#### 8.2.4 Replay and backfill (projections)

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

### 8.3 Reactors under F

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
| Scaling | n/a | Consistent-hash partitions, competing consumers for order-insensitive reactors. Spreading across instances needs app-side queue assignment (§8.1). |
| Visibility | Logs only | Per-queue depth, rates, unacked and DLQ counts in the LavinMQ UI and metrics, free |
| Latency | ≤ 100 ms poll | Relay poll interval (pgmq read, about 100 ms) plus broker push (ms). The relay can also LISTEN to remove the poll. |

### 8.4 Projections under F

**Required changes**

| Where | Change |
|---|---|
| `apply` blocks | Same `write { }` migration as in C, so applies and receipts commit together. Unmigrated projections need idempotent applies (upserts, or a guard on `aggregate_version`). |
| Batching | `prefetch = N`. Apply up to N messages (or wait up to 50 ms) in one projection DB transaction with their receipts, then `ack(multiple: true)` on the last delivery tag. |
| New projection or rebuild | F-a handover (§8.2.4): declare the queue, backfill from Postgres, consume with receipt deduplication. Needs a runner command: `rebuild(P)` = pause consumer, truncate, backfill, resume. |
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

### 8.5 Infrastructure and platform changes (F)

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

### 8.6 Effort (F)

| Phase | Scope | Size |
|---|---|---|
| F1 | `ES::Queue` read access, `EventStore#transaction` (shared with C3), receipts tables | S–M |
| F2 | `crystal-es-amqp`: relay, topology sync, runner with app-side queue assignment, retry, park, DLQ, outbox archive and reconciliation | M–L |
| F3 | Projection `write` migration, F-a backfill and handover, `rebuild` command | M |
| F4 | Infrastructure (compose, CI, production cluster), operations runbooks, metrics | S–M, plus ongoing operations |


---

## 9. Postgres-only (C) vs LavinMQ (F) in detail

This section compares the two leading options on equal terms. Running a LavinMQ (or RabbitMQ) broker is
treated as **acceptable**: no extra weight is given to "no new infrastructure". The question is which
design delivers events to reactors and projections better.

### 9.1 Framing: a log or a queue?

- **A log** (C, Kafka, LavinMQ streams) keeps every event at a stable position. A consumer *is* a
  position. Replay, rebuild, "how far behind" and "has X seen E" are all questions about positions.
- **A queue** (LavinMQ/RabbitMQ classic and quorum queues, pgmq, SQS) holds work items that disappear
  once acknowledged. A consumer is "whoever acks next". Retries, dead-lettering, delays and priorities
  are the strengths. Replay is not a concept.

The two handler types are shaped differently:

| | Projections | Reactors |
|---|---|---|
| Must be able to start from the beginning | **Yes**: every new projection and every rebuild | No: a reactor must never re-run history |
| Needs ordering | Yes, per aggregate, and globally for cross-aggregate (DCB) read models | Yes, per aggregate (workflow steps) |
| Benefits from dead-lettering | Rarely: skipping an event makes the read model wrong | Sometimes, for order-insensitive reactors |
| Natural fit | **Log** | **Queue or log**, both work |

C serves both handler types from one log. F serves both from queues, and has to bolt a log-like path
(a Postgres backfill) onto projections.

### 9.2 Dimension by dimension

| Dimension | C: Postgres subscriptions | F: LavinMQ | Edge |
|---|---|---|---|
| **Where "handler X has processed event E" lives** | One checkpoint `(transaction_id, id)` per subscription, committed **in the same transaction** as the handler's writes | Broker queue state (unacked/acked) **plus** a receipts table in the handler's DB. Ack happens after commit, so the two are reconciled by deduplication. | **C**: one source of truth, no reconciliation |
| **Durability of delivery** | The event store is the delivery state. If an event is committed, every subscription will reach it. | The relay deletes from the pgmq outbox after the publisher confirm. In LavinMQ's clustered mode, the leader confirms once a write is in its page cache and *queued* for replication. A leader loss right after can lose messages the relay already removed from the outbox ([LavinMQ HA](https://lavinmq.com/documentation/clustering), [etcd and leader election](https://www.cloudamqp.com/blog/etcd-and-leader-election-in-lavinmq-clustering.html)). Recovery means re-relaying from the event store, which needs a position (back to C's `xid8`) or a time-window republish with receipt deduplication. | **C** |
| **Per-aggregate ordering** | Yes, with `(transaction_id, id)` order and partitions by `hash(aggregate_id)` | Yes, with one relay in outbox order, a single-active-consumer queue, and consistent-hash partitions on `aggregate_id` | Tie |
| **Cross-aggregate / causal order** (DCB read models folding several aggregates or tags) | A total order consistent with causality (a command that read E sorts after E) | Preserved through the single relay, and per queue while P = 1. Lost across partitions (as in C). | Tie (C is simpler to reason about) |
| **Spreading work across instances** | Custom: try-lock loop with a per-instance cap and a heartbeat table for rebalancing | **Also custom.** LavinMQ activates the *first registered* consumer on a single-active-consumer queue, fails over in connection order, and disables consumer priorities on those queues ([docs](https://lavinmq.com/documentation/single-active-consumer), [consumer priorities](https://lavinmq.com/documentation/consumer-priorities)). Left alone, the first instance to boot runs all ~180 handlers. You need app-side assignment (each instance consumes only its share of queues and rebalances on membership change), or exclusive consumers used as a lock (the same pattern as C's try-lock). | Tie, the same work in both |
| **Failover** | The advisory lock is released when the session dies. Detection is by TCP keepalive or `tcp_user_timeout`, typically seconds. | The broker notices the consumer disconnect (AMQP heartbeat) and activates the next consumer. Unacked messages are redelivered. | Slight **F** (built in, well tested) |
| **Effectively-once** | Checkpoint in the handler transaction. Nothing to prune. | Receipt in the handler transaction, then ack. Receipts tables need pruning, plus a redrive horizon. | **C** (fewer parts) |
| **Poison event** | Retry with backoff, then `paused`. Operator `skip(event_id)`. Ordering is never broken implicitly. | Retry while unacked, then park (stop the consumer) or dead-letter. The DLQ is inspectable and redrivable in the UI. | **F** for tooling, C for safety by default |
| **New projection / rebuild** | Start at position zero: the same code path as live. | Declare the queue first, backfill from Postgres, then consume with receipt deduplication. **Two paths** per rebuild, and the queue buffers live events during the backfill. | **C**, clearly |
| **Read-your-projection** (`await` projection ≥ event) | Possible, because positions are comparable | Not possible, because broker progress isn't comparable to event positions | **C** |
| **Lag and observability** | Exact lag (`head − checkpoint`), but dashboards and CLI are yours to build | Queue depth, rates, unacked and DLQ counts in the LavinMQ UI and Prometheus metrics, out of the box | **F** |
| **Load on Postgres** | One live-tail query per instance per wake-up, plus catch-up reads during rebuilds | Relay reads of pgmq, plus **one `fetch_event` per handler per event** (header-only messages, to keep bodies out of the broker) | Roughly a tie at today's volume. F wins only if bodies travel in messages. |
| **Latency** | NOTIFY-driven, milliseconds | Relay poll (or LISTEN) plus push, milliseconds | Tie |
| **Throughput ceiling** | Bounded by Postgres reads and one consumer per partition. Comfortably thousands of events/s. | Higher. Broker fan-out takes load off Postgres. | **F**, but only at volumes far beyond the current ones |
| **Connection pooling** | Needs direct (non-transaction-pooled) connections for the advisory-lock sessions | Works behind any pooler | **F** |
| **Schema migration** | `xid8` column, default and index (additive, built concurrently) | None needed for live delivery (the pgmq outbox order is enough) | **F** |
| **Cutover from today** | Projections one by one (rebuild). Reactors in a **write pause of seconds**. | No write pause: the existing outbox becomes the relay input | **F** |
| **Testing** | The in-memory store implements the same subscription semantics, so the whole runner is testable in unit specs | Broker needed in CI for integration specs. Unit specs keep using `EventBus#publish`. | **C** |
| **Operations** | Postgres only. Alert on `xmin` age and subscription status. | High availability means a LavinMQ cluster (3 nodes) plus etcd (3 nodes), with upgrades, TLS, credentials and disk monitoring. Even if welcome, it is a second stateful system on the critical path of every workflow. | **C** |
| **Library fit** | Core crystal-es ("optimized for PostgreSQL") | A separate `crystal-es-amqp` shard, plus core changes for the bound store and outbox access | **C** |
| **External consumers** (other services) | Through option I: a publisher subscription to any broker | Built in: other services bind their own queues | **F** (or C + I) |

### 9.3 Reactors: scenario walk-through

| Scenario | C | F |
|---|---|---|
| Instance crashes **after** the reactor committed, before progress is recorded | Impossible: the checkpoint is in the same commit | Redelivered by the broker. The receipt is found and the message is acked without re-running. |
| Instance crashes **before** commit | The transaction rolls back. The next lock holder re-runs the reactor from the checkpoint. | The message is unacked, so the broker redelivers it to the next consumer and the reactor re-runs. |
| Broker leader fails right after a publisher confirm | n/a | The message may be missing on the new leader, and the outbox row is already deleted, so the workflow step silently never runs. Needs a reconciliation job: compare reactor receipts against events and re-relay gaps. |
| Reactor raises on one event | Retries, then pauses only this reactor (or partition). Later events wait, so order is kept. | Retries unacked, then parks the queue (order kept) or dead-letters it (order broken). |
| Deploy with rolling restarts | Graceful shutdown releases locks, and other instances pick up | Consumers cancel, and the broker activates the next consumer |
| Scale from 1 to 3 instances | Locks spread by the per-instance cap and heartbeat rebalance | First-registered wins, so all reactors stay on the first instance until the app-side assignment moves them |
| Reactor reads a projection that hasn't caught up | `await(projection, event.position)` with a timeout, or hydrate instead | Hydrate instead, or accept staleness |
| Reactor triggers a side effect (mail, HTTP) | Through a job enqueued in the same transaction (if jobs share the DB) or at-least-once jobs | The same, and jobs can also move to LavinMQ (see §10) |

**Verdict for reactors:** F is fully viable for reactors, which are queue-shaped. Its operational
pluses (failover, DLQ UI, no write-pause cutover) are real. They are offset by two extra mechanisms:
receipts plus ack reconciliation, and the broker-durability gap. Work distribution is no better.
**Slight edge C**, mostly for having one mechanism instead of two.

### 9.4 Projections: scenario walk-through

| Scenario | C | F |
|---|---|---|
| Add a new projection | Register it. It starts at zero, catches up on one instance, then joins the tail. | Declare and bind the queue, run the Postgres backfill with receipts, then switch to the queue. Deduplicate the overlap. |
| Rebuild after a bug fix | `rebuild(P)`: lock, truncate, reset the checkpoint, catch up | Pause the consumer, truncate, backfill from Postgres, resume, and deduplicate events buffered meanwhile |
| Projection schema change (blue/green) | A new subscription name per fingerprint into a new table, catch up, swap | A new queue per fingerprint, backfill and handover, swap |
| Projection stored in another database or a search index | Checkpoint stored next to the data (or idempotent writes) | Receipts next to the data (or idempotent writes) |
| "Show data as of event E" / health check on lag | Exact: `head − checkpoint` | Approximate: queue depth |
| Broker data loss | n/a | Re-backfill the affected projections from Postgres (a rebuild) |
| Throughput during a rebuild | Batched reads and batched commits (500 events per transaction) | Backfill as in C, then the queue drains at broker speed |

**Verdict for projections: C, clearly.** Under F, every lifecycle event of a projection (create,
rebuild, migrate, recover) leaves the broker and runs C's read path anyway. F therefore *contains* a
partial C for projections, plus a handover protocol.

### 9.5 Does a "free" broker change the recommendation?

**Not for internal event delivery.** Removing the infrastructure cost takes away one of C's advantages,
but that wasn't the decisive one. The decisive ones are structural:

1. **One path for projections.** Replay, rebuild and live tailing are the same code under C. Under F,
   the Postgres read path is needed anyway, and the broker adds a second path plus a handover.
2. **Progress lives in the same transaction as the effect.** A single comparable position gives
   effectively-once, exact lag, `await` and trivial resets. F splits this between broker state and
   receipts.
3. **No second durable state to lose or reconcile.** With F, a broker failover can lose
   confirmed-but-unreplicated messages after the outbox row is gone. Detecting and repairing that
   needs positions, which is C's mechanism again.
4. **F's operational edge on distribution doesn't exist with LavinMQ.** Single active consumer always
   activates the first consumer, so balancing is app-side work in both designs.

What a welcome broker *does* change is **where LavinMQ is used**:

- **Jobs and side effects.** Background jobs (mail, HTTP, LLM calls, imports) are genuinely
  queue-shaped: delays, retries with backoff, dead-letter exchanges, priorities, per-queue concurrency.
  LavinMQ is a better home for them than pgmq. Because they are at-least-once with idempotency keys
  already, they don't need the event store's ordering or atomicity. The enqueue still has to be
  reliable: publish from a job outbox, or after commit with a retry.
- **Integration events.** Other services subscribe to a LavinMQ exchange fed by a C publisher
  subscription (option I). This gives them broker semantics without making the broker part of the
  internal consistency story.

**When F (LavinMQ for event delivery) is the better choice:**

- Several *other services* consume the same events, and you want one fan-out mechanism for internal
  and external consumers.
- A transaction-pooling PgBouncer is mandatory and direct connections for lock sessions aren't allowed.
- No write pause is acceptable for the cutover, and the reactor migration can't be staged otherwise.
- Sustained volume (many thousands of events/s) makes Postgres tailing plus catch-up reads a measured
  bottleneck.
- The team already runs LavinMQ in HA and would rather debug a broker than a custom runner.

**Hybrid splits considered and rejected:**

- *C for projections and F for reactors.* Both need the bound store. This runs two delivery
  mechanisms, two failure models and two sets of operations tools to gain broker monitoring for
  reactors. It's only worth it if one of the "F is better" conditions applies to reactors alone.
- *F live with a C backfill.* That is F-a, which is already the F design. See 9.4 for why it is
  heavier.

### 9.6 Effort side by side

| Work item | C | F | Shared |
|---|---|---|---|
| Leader lock and retry instead of archive (option A) | ✓ | ✓ | **yes**, do first |
| `EventStore#transaction` (bound store) | ✓ | ✓ | **yes** |
| Projection `write { }` helper and migration | ✓ | ✓ | **yes** |
| `causation_id` / `correlation_id` headers | optional | optional | **yes** |
| `xid8` column, `Position`, `read_all` | ✓ | for reconciliation only | |
| Checkpoint stores, lock manager, tail reader, runner | ✓ | | |
| Relay, topology sync, AMQP runner, receipts and pruning | | ✓ | |
| Backfill and handover protocol | (it is the subscription) | ✓ | |
| Work-distribution logic | ✓ (lock cap and rebalance) | ✓ (queue assignment) | same problem |
| Operations: dashboards, CLI | build it | mostly from the broker | |
| Infrastructure: LavinMQ HA (3 nodes + etcd), CI, compose | | ✓ | |
| **Total** | **L** | **L, plus broker operations** | |

About half the effort is shared, and it comes first. That keeps the decision reversible until the
runner work starts.

---

## 10. Recommended path

**Phase 0: make multi-instance safe today (S).**
- Single-dispatcher advisory lock around `process_queue` and `Projection#init` in the application, or
  as an opt-in helper in crystal-es.
- Retry with backoff instead of archiving immediately (`read_ct` is already on `Queue::Entry`), so a
  transient error no longer drops an event for all handlers.

**Phase 1: the shared foundation (M). C and F both need it.**
- `EventStore#transaction`: a transaction-bound event store (§7.2.4).
- The projection `write { }` helper (§7.2.5). Migrate the projections mechanically, one at a time.
- Optional `causation_id` and `correlation_id` header fields (§3.4 layer 2).
- **Decision gate:** confirm C, or switch to F if one of the conditions in §9.5 applies.

**Phase 2: the read position (S–M).**
- The `transaction_id xid8` column, default and expression index (§3.1), applied in `setup`'s
  existing-store branch as well.
- `EventStore#read_all(after : Position, limit)` and `#head`, with in-memory parity.

**Phase 3: subscriptions for projections (M).**
- Checkpoint stores, lock manager (with a per-instance cap and rebalancing), tail reader with NOTIFY,
  runner, and the failure policy.
- Migrate projections one at a time by rebuilding them as subscriptions (no write pause). `init`
  becomes obsolete.

**Phase 4: subscriptions for reactors (M).**
- `ReactorSubscription` with the bound store, partitions for hot reactors, and `await`.
- Cutover in a write pause of a few seconds (§7.6), then remove the pgmq event trigger.

**Phase 5: operations (S–M).**
- Lag and status per subscription, `xmin`-age alerting, and a `pause`/`resume`/`skip`/`rebuild` CLI.

**Phase 6: if a broker is welcome, use LavinMQ where it fits (M each, independent).**
- Move background jobs from pgmq to LavinMQ (delays, retries, dead-letter exchanges). Enqueue
  reliably, through a job outbox or after commit with a retry.
- Add an `ES::Publisher` with a LavinMQ adapter (option I), so other services can consume integration
  events.

### Compatibility notes (AGENTS.md)

- All schema changes are additive. There is no `UPDATE` on `eventstore.events` (the NULL
  `transaction_id` of old rows is handled by `COALESCE`), and indexes are built `CONCURRENTLY`.
- New base-class methods (`read_all`, `head`, `transaction`) get non-abstract defaults that raise
  `NotImplemented`, so third-party adapters keep compiling.
- The in-memory event store gets the same subscription semantics, as shared spec scenarios.
- Lock and concurrency specs must be shown to fail with the lock removed. Racing fibers open their
  connections up front.
- This is a minor version bump (new behaviour, deprecations), with upgrade notes: the migration, the
  per-subscription switch, and `pg_monitor` grants on the new tables.

---

## 11. Open questions

1. Is Kafka (or another broker) actually present in the production environment? If so, which external
   consumers would use it? This decides whether phase 6 is needed.
2. Do the event store, projection and jobs databases point to the same database server in production?
   Same-DB makes effectively-once trivial for projections and jobs. Separate DBs mean checkpoints live
   next to each projection.
3. Is a transaction-pooling PgBouncer in the path? If so, use lease rows instead of session advisory
   locks, or give the lock holders a direct connection.
4. Expected event volume and the hottest handlers: this decides whether any subscription needs P > 1
   at the start.
5. Should ordering be per aggregate (`aggregate_id`) or per DCB tag for tag-only events? This affects
   the partition key definition.
6. If LavinMQ is introduced, would it run as a highly available cluster (3 LavinMQ nodes plus etcd) or
   as a single node? This decides how much the durability gap in §8.2.1 matters, and whether moving
   jobs to it (§10, phase 6) is worthwhile.
7. Are other services planned that should consume domain events? If yes, the integration-event
   publisher (option I) moves up, and F's "external consumers" advantage gets more weight (§9.5).
