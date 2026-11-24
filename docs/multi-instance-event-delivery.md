# Event delivery across multiple application instances

Status: research and options, no decision yet. Written against crystal-es 0.11.3 and a production application built on it, as of 2026-11-24.

Required changes for every option, with in-depth designs of C and F split by reactors and
projections: [multi-instance-event-delivery-changes.md](./multi-instance-event-delivery-changes.md).

## TL;DR

- Today, events reach reactors and projections through **one pgmq queue** filled by a trigger on
  `eventstore.events`, and an **in-process `EventBus`** fans each message out to every handler in
  sequence. This is correct for one instance. Run two instances and you get competing consumers on one
  queue: per-aggregate ordering is lost, projections can apply events out of order, `Projection#init`
  races, and one failing handler dead-letters the event for every other handler.
- The core problem is not transport. It is **(1) a commit-ordered, gap-free position to read from**,
  **(2) independent progress (a checkpoint) per handler**, and **(3) exactly one active consumer per
  handler, or per partition of a handler**. Every broker option still needs an ordered relay out of
  Postgres on the producing side, because the event store is the source of truth. That relay can be
  (1), or the existing pgmq outbox read by a single relay, which keeps per-aggregate order but no
  replayable position (see the companion document, §3.2.1).
- **Recommendation: use the event store itself as the stream, with "catch-up subscriptions" in Postgres
  (option C).** Add a transaction-id column (`xid8`) to `eventstore.events` so readers have a safe
  high-water mark. Keep one checkpoint row per subscription, and hold a session advisory lock per
  subscription (or per partition) to pick the single active consumer. Use LISTEN/NOTIFY so consumers
  wake up instead of polling hard. This needs no new infrastructure. It also gives every projection
  its own pace, persistence layer, retry policy and rebuild path, and gives reactors effectively-once
  execution when the reactor's appends and its checkpoint commit in one transaction.
- **Do option A now** (one leader instance consumes the existing queue, chosen with an advisory lock).
  It is a few days of work and makes running several instances for HTTP traffic safe immediately.
- **Add a broker later only behind a "publisher" subscription (option I)** if other services need the
  events or throughput outgrows Postgres. Kafka, NATS JetStream and LavinMQ then become adapters, not
  the backbone.

> Note on "the existing infrastructure component Kafka": the application this was
> researched against runs Postgres as its only infrastructure for events. No Kafka appears in its setup. This document therefore
> treats **Postgres as the only existing component**. If Kafka does run in production outside
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
- Ordering requires single-active-consumer or a consistent-hash partition per queue. Feature parity
  between RabbitMQ and LavinMQ for these (SAC, consistent-hash exchange, stream filtering) should be
  verified for the specific version.
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

## 5. Comparison

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

## 6. Recommended path

**Phase 0: make multi-instance safe today (S).**
- Single-dispatcher advisory lock around `process_queue` and `Projection#init` in the application, or as an
  opt-in helper in crystal-es.
- In the platform, retry instead of immediately archiving, so a transient error no longer drops an
  event for all handlers.

**Phase 1: the read position (S–M, library).**
- Add the `transaction_id xid8` column, default and expression index (3.1), all additive and applied in
  `setup`'s existing-store branch.
- Add `EventStore#read_all(after : Position, limit) : Array(Event)` with a watermark and a `Position`
  struct `(transaction_id, id)`. Base class default raises `NotImplemented` (AGENTS.md rule for
  subclassed bases). In-memory parity uses a monotonic counter under a mutex.
- Add optional `causation_id` and `correlation_id` header fields (3.4 layer 2).

**Phase 2: subscriptions for projections (M).**
- Add `eventstore.subscriptions` (checkpoint, status, error, retries) and a projection-DB-side
  checkpoint table for projections that live elsewhere.
- Add an `ES::Subscription` runner with an advisory-lock single consumer, NOTIFY wake-up, a shared tail
  reader, batched apply plus checkpoint in one transaction, and backoff with `failing` status.
- Projections opt in per class (`define_projection … subscription: true`, or registry-level). The
  `EventBus` keeps working for the rest, so migration can be gradual.
- Replace `Projection#init` with "subscription starts at (0,0)". Add a blue/green rebuild keyed on the
  projection fingerprint.

**Phase 3: subscriptions for reactors (M).**
- Add a transaction-joining event store (`EventStore#within(connection)`) and the transactional inbox
  (3.4 layer 1).
- Reactor subscriptions with optional partitions (3.5) for hot reactors.
- In the application: decide whether the jobs database (jobs) shares the event store DB so that job enqueues join the
  reactor transaction.
- Remove the pgmq event trigger once every handler is on a subscription. `ES::QueueAdapters::Postgres`
  stays for compatibility and is deprecated in the CHANGELOG.

**Phase 4: operations (S–M).**
- Lag per subscription (`watermark − checkpoint`), `xmin` age alerting, `pause`/`resume`/`reset`/
  `skip-event` admin API, and an instance heartbeat for lock rebalancing.

**Phase 5 (only if needed): publishers (M each).**
- `ES::Publisher` plus one adapter (Kafka, NATS or LavinMQ) for consumers outside the application.

### Compatibility notes (AGENTS.md)

- All schema changes are additive. There is no `UPDATE` on `eventstore.events` (the NULL
  `transaction_id` of old rows is handled by `COALESCE`), and indexes are built `CONCURRENTLY`.
- New base-class methods (`read_all`, `within`) get non-abstract defaults that raise
  `NotImplemented`, so third-party adapters keep compiling.
- The in-memory event store gets the same subscription semantics, as shared spec scenarios.
- Lock and concurrency specs must be shown to fail with the lock removed. Racing fibers open their
  connections up front.
- This is a minor version bump (new behaviour, deprecations), with upgrade notes: the migration, the
  per-subscription switch, and `pg_monitor` grants on the new tables.

---

## 7. Open questions

1. Is Kafka (or another broker) actually present in the production environment? If so, which external
   consumers would use it? This decides whether phase 5 is needed.
2. Do the event store, projection and jobs databases point to the same database server in production?
   Same-DB makes effectively-once trivial for projections and jobs. Separate DBs mean checkpoints live
   next to each projection.
3. Is a transaction-pooling PgBouncer in the path? If so, use lease rows instead of session advisory
   locks, or give the lock holders a direct connection.
4. Expected event volume and the hottest handlers: this decides whether any subscription needs P > 1
   at the start.
5. Should ordering be per aggregate (`aggregate_id`) or per DCB tag for tag-only events? This affects
   the partition key definition.
