# Design: Event Payload Encryption

Status: **proposal** — several decisions are still open, see [Open questions](#open-questions).

## Goal

Encrypt the `body` of selected events at rest, using envelope encryption: a per-scope
data encryption key (DEK) encrypts event bodies, and an application-held key encryption
key (KEK) encrypts the DEK. Only the wrapped DEK is stored, so key management collapses
to managing a single application key.

## Threat model

State this up front, because it bounds every decision below.

**Protected:** event bodies in `eventstore.events` — database dumps, physical backups,
read replicas, a DBA with `SELECT`, a stolen volume. Plus optional crypto-shredding: destroy
one DEK and every event body under it becomes permanently unreadable.

**Not protected:** the event *header* (it is indexed and drives the flattened view, so it
stays plaintext), application memory, logs, and — importantly — **projection tables**.
A projection built from an encrypted event stores whatever it extracted in the clear.
Encryption stops at the event store.

---

## 1. Where the seam goes

Encryption is a property of *storage*, so it belongs in the event store adapters. The
adapters take an optional `ES::Encryption` collaborator and maintain one invariant:

> An `ES::EventStore::Event` handed out by a store always carries a **plaintext** body.

That keeps the envelope from leaking into aggregates, projections, reactors and the bus,
and it keeps `append`/`fetch_*` symmetric. `ES::Encryption` holds the shared `seal`/`open`
logic, so each adapter is two lines.

Passing `nil` disables the whole feature and reproduces today's behaviour exactly.

### Separately: collapse the triplicated read path

Three call sites build an event from a stored row today:

- `src/components/aggregate.cr:65`
- `src/components/projection.cr:62`
- `src/components/projection.cr:83`

They should collapse into `ES::EventHandlers#materialize(stored) : ES::Event`. This is
worth doing on its own merits, and it gives the missing-key policy (§6) a single place
to live.

### Pre-existing bug on the same path

`src/components/aggregate.cr:65` calls `@event_handlers.event_class(...)`, but the ivar
is declared only in a **comment** on line 40. Crystal only typechecks called methods and
no spec exercises `Aggregate#hydrate`, so this has never been compiled. Hydration is
exactly the path decryption plugs into, so this needs fixing (declare the ivar, take it
in the constructor like `Projection` does) and covering with a spec before anything is
built on top.

---

## 2. Header change

```crystal
struct Header
  getter encryption_key_id : UUID? = nil
  # ...
  protected def encryption_key_id=(@encryption_key_id : UUID?); end
end
```

A nilable field with a default is backward compatible under `JSON::Serializable`: existing
rows without the key deserialise to `nil`. **No migration of `eventstore.events` is needed.**

`append` sets it via the protected setter once the key is resolved. The alternative — a
`Header#with_encryption_key` copy — keeps the struct immutable but means the in-memory
event that `bus.publish` fans out disagrees with what was persisted.

---

## 3. The key table

Not event sourced, as intended. Beyond the three columns in the original sketch:

```sql
CREATE TABLE "eventstore"."encryption_keys" (
  "encryption_key_id"             UUID PRIMARY KEY,
  "scope"                         TEXT        NOT NULL,
  "encrypted_encryption_key"      BYTEA,
  "application_encryption_key_id" TEXT        NOT NULL,
  "algorithm"                     TEXT        NOT NULL DEFAULT 'aes-256-gcm',
  "created_at"                    TIMESTAMPTZ NOT NULL DEFAULT now(),
  "rewrapped_at"                  TIMESTAMPTZ,
  "destroyed_at"                  TIMESTAMPTZ
);

CREATE UNIQUE INDEX encryption_keys_active_scope_idx
  ON "eventstore"."encryption_keys" ("scope") WHERE "destroyed_at" IS NULL;

CREATE INDEX encryption_keys_app_key_idx
  ON "eventstore"."encryption_keys" ("application_encryption_key_id");
```

Why each addition:

- **`scope`** — what the key protects (aggregate id by default). Makes `key_for(scope)` an
  idempotent get-or-create. The partial unique index allows exactly one *live* key per scope
  while permitting a fresh key after a shred, so a re-registered subject isn't permanently
  locked out.
- **`algorithm`** — crypto agility. Without it, changing algorithm later means guessing at
  read time.
- **`destroyed_at` + nullable `encrypted_encryption_key`** — shredding sets the wrapped key
  to `NULL` and stamps the timestamp. Keeping the row preserves the audit trail and lets the
  read path distinguish *"deliberately destroyed"* from *"corrupt / missing"*. Deleting the
  row loses that distinction.
- **`application_encryption_key_id` indexed** — KEK rotation re-wraps by old KEK id; that
  needs an index.

---

## 4. On-disk envelope

The `body` column stays `jsonb NOT NULL`:

```json
{
  "__es": 1,
  "alg":  "aes-256-gcm",
  "kid":  "0190a3f2-...",
  "iv":   "<base64>",
  "ct":   "<base64>",
  "tag":  "<base64>"
}
```

The `__es` discriminator is what makes rollout free: the read path checks for it, so
encrypted and plaintext bodies coexist in one store and encryption can be switched on for
new events with **no backfill and no rewrite of history**.

### Binding ciphertext to its event

Ciphertext should not be transplantable from one event row to another. The usual answer is
GCM's AAD — but Crystal's `OpenSSL::Cipher` exposes `gcm_tag`/`gcm_tag=` and no AAD setter
(`LibCrypto.evp_cipherupdate` is declared, but `Cipher`'s `@ctx` is private, so real AAD
would mean reimplementing the wrapper).

So bind inside the plaintext instead:

```
plaintext = {"h": sha256(event_id|aggregate_id|aggregate_version|event_handle), "b": <body>}
```

On open, recompute the digest from the header actually read and compare. Same anti-transplant
guarantee, pure stdlib, no FFI.

---

## 5. Declaring that an event is encrypted

```crystal
define_event("customer", "customer_registered", encrypted: true) do
  attribute :name, String
  attribute :iban, String
end
```

Generates `self.encrypted? : Bool`, defaulting to `false` on `ES::Event`. Compile-time,
greppable, auditable in review — a runtime policy object would hide which events carry PII.

Scope resolution is configurable, defaulting to the aggregate:

```crystal
ES::Config.encryption.scope = ->(header : ES::Event::Header) { header.aggregate_id.to_s }
```

---

## 6. Missing-key policy

Once shredding exists, hydration and replay *will* meet events whose key is gone. One global
setting is wrong here, because the right answer differs per call path:

| Path | Policy | Why |
|---|---|---|
| `Aggregate#hydrate` | **raise** | Rebuilding state from a silently partial stream is a correctness bug, not a degraded read. |
| `Projection#replay` / `#init` | **skip** or **redact** | Read models must remain rebuildable *after* an erasure, or shredding breaks every replay forever. |

So the policy is a parameter of the read path, not a config global. `redact` constructs the
event with an empty/default body; `skip` drops it entirely. A new
`ES::Exception::KeyUnavailable` distinguishes destroyed from merely absent.

---

## 7. Key providers and rotation

The library must never see the KEK material handling policy, so:

```crystal
abstract class ES::KeyProvider
  abstract def wrap(dek : Bytes) : {String, Bytes}   # => {application_encryption_key_id, wrapped}
  abstract def unwrap(application_encryption_key_id : String, wrapped : Bytes) : Bytes
end
```

This interface fits both a raw in-process secret and an opaque KMS/HSM handle. Ship a
`Static` provider (KEK from ENV) for dev and tests.

**KEK rotation is cheap** and is the main payoff of this design: re-wrap every DEK under
the new KEK, touch zero events. Worth a first-class `rewrap_all(to:)` helper.

**DEK rotation is not supported.** Re-encrypting existing bodies means rewriting the event
store, which contradicts immutability. Because the key id lives per-event in the header,
a new key simply starts being used for new events — which is the useful part of rotation
anyway.

---

## 8. DEK caching

Unwrapping per event is a KMS round trip per event; hydrating a 500-event aggregate would
be 500 of them. With aggregate-scoped keys the hit rate is essentially perfect, so a bounded
LRU of unwrapped DEKs keyed by `encryption_key_id` is required, not optional. The cost is
plaintext DEKs resident in process memory — bounded size plus an optional TTL, documented.

---

## 9. Blast radius

| Area | Impact |
|---|---|
| `eventstore.events` schema | none |
| `eventstore_flattened` view | none — body is passed through |
| pgmq queue | none — the trigger sends `NEW.header` only (`adapters/queues/postgres.cr:23`) |
| `bus.publish` | none — the in-memory event keeps its plaintext body |
| Existing plaintext events | none — `__es` discriminator |
| SQL against `body->>'field'` | **breaks** for encrypted event types (none in the library today) |
| Projection tables | hold plaintext; shredding requires purge or replay |

---

## 10. Rollout

1. Ship with `encryption = nil`. Zero behaviour change.
2. `key_store.setup` creates the key table.
3. Mark new event classes `encrypted: true`. History keeps reading.

No backfill path. Encrypting existing events is an event-store rewrite — dangerous, and
arguably not the library's job.

---

## Open questions

1. **Key scope.** Per aggregate (proposed default), per data subject (better for GDPR when
   one person's data spans several aggregates), or per tenant? The `scope` column supports
   all three; the default and the docs should match the real intent.
2. **Whole body vs. per attribute.** Whole-body is proposed. Per-attribute
   (`attribute :iban, String, encrypted: true`) keeps non-sensitive fields queryable in JSONB
   and indexable by projections, at the cost of a per-field envelope and more surface.
3. **Is crypto-shredding actually a goal**, or is at-rest confidentiality the whole ask?
   If shredding is out of scope, §6 and the `destroyed_at` machinery disappear and the
   design gets materially smaller.
4. **Projections.** Should the library help (mark columns as derived-from-encrypted, offer a
   purge hook), or is the read model entirely the application's problem?
5. **`application_encryption_key_id` type** — free-form `String` (KMS ARN, Vault path,
   version tag) or `UUID`? Proposal: `String`.
6. **Header mutation.** Is a protected setter on `Header` acceptable, or should `append`
   build a copy via `Header#with_encryption_key`?
7. **Crypto agility.** Hardcode `aes-256-gcm` and record the name for future migration
   (proposed), or a pluggable `Cipher` abstraction from day one?
8. **Test target.** In-memory keystore only, or should specs run against the real Postgres
   in `docker-compose.test.yml`?
