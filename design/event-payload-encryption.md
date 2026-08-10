# Design: Event Payload Encryption

Status: **implemented**. This records the reasoning; `README.md` documents the API.

## Goal

Crypto-shredding. An event store is immutable, so once personal data lands in a body
there is no way to erase it — which leaves an erasure request unanswerable short of
rewriting history. Encrypting the body under a key that can be destroyed makes erasure
a `DELETE` of 32 bytes instead.

Encryption at rest is the side effect, not the driver.

## Threat model

**Protected:** event bodies in `eventstore.events` — dumps, backups, replicas, a DBA with
`SELECT`, a stolen volume — and erasure by key destruction.

**Not protected:** the event *header* (indexed, drives the flattened view, so it stays
plaintext), application memory, logs, and **projections**. A projection built from an
encrypted event stores whatever it extracted in the clear. Encryption stops at the event
store; read models are treated as temporary and rebuilt independently.

---

## Decisions

### Whole body, whole shred

Not per-attribute. Anything that must survive an erasure — a retained financial record,
an anonymised aggregate — is extracted by the application before the key goes. Field-level
encryption would keep some JSONB queryable, at the cost of a per-field envelope and a much
larger surface; it can be added later without changing the storage format.

### The key is chosen at construction

`define_event(..., encrypted: true)` makes `encryption_key_id` a **required** parameter of
the generated constructor. The declaration is compile-time and greppable; the value is
dynamic.

That combination is the point. A purely per-instance key means forgetting to pass one is a
silent plaintext write. A statically derived key (say, always the aggregate id) cannot
express the case that actually matters: an order aggregate holding events about a customer,
which must be keyed by that customer so erasing them erases the right thing.

Because the key is known at construction, the header carries it from the start and
`ES::Event::Header` stays immutable — no setter, no mutation during `append`.

### References run one way

An event header points at a key. The key table points at nothing.

The reverse lookup an erasure needs is answered outside the key table, by
`ES::EventStore#encryption_key_ids(aggregate_id)` reading distinct key ids off a stream.
A subject spanning several aggregates is the application's to map.

The alternative — a `scope` column on the key table — is more convenient and was rejected:
it would put domain identifiers, themselves frequently personal data, directly beside the
keys protecting them.

### A destroyed key is reported, not raised on

`ES::EventStore::Event#shredded?`. The adapters decrypt, so a store always hands back a
plaintext body, but a shredded event must not blow up `fetch_events` — because the right
response differs by caller:

| Caller | Behaviour | Why |
|---|---|---|
| `Aggregate#hydrate` | raise | Rebuilding state from events you cannot read is a correctness bug, not a degraded read. |
| `Aggregate#hydrate(skip_shredded_events: true)` | bump version, continue | An order whose customer was erased should still hydrate — but you opt into the incomplete state. |
| `Projection#replay` / `#init` | skip | Read models must stay rebuildable *after* an erasure, or one request breaks every future replay. |

A key row that is **missing entirely** raises instead: that means the store is pointed at
the wrong database, not that anything was erased. Distinguishing the two is why `destroy`
nulls the material and keeps a tombstone rather than deleting the row.

### Envelope inside the existing column

`body` stays `jsonb NOT NULL`:

```json
{"__es":1,"alg":"...","kid":"<uuid>","iv":"<b64>","ct":"<b64>","tag":"<b64>"}
```

The `__es` discriminator lets encrypted and plaintext bodies coexist in one store, so
encryption switches on for new events with **no migration and no backfill**. Adding
`encryption_key_id` to the header as a nilable field with a default is likewise backward
compatible under `JSON::Serializable` — old rows read back as `nil`.

There is no path to encrypt existing events. That is an event-store rewrite, and not the
library's job.

### AES-256-CBC + HMAC-SHA256, not GCM

Crystal's `OpenSSL::Cipher` gained `gcm_tag`/`gcm_tag=` only after 1.17, and released
versions bind neither those nor `EVP_CIPHER_CTX_ctrl` — reaching GCM means reopening a
stdlib class to get at its private context. Encrypt-then-MAC gives the same properties out
of API stable for years and keeps the shard working on the Crystal versions `shard.yml`
claims (`>= 1.14.0`).

One data key in, two subkeys derived from it, so the same bytes never both encrypt and
authenticate. The tag is verified before anything is decrypted.

### Ciphertexts are bound to their event

A digest of `event_id|aggregate_id|aggregate_version|event_handle` travels *inside* the
plaintext and is checked on open, and the envelope's `kid` is cross-checked against the
header. Without this, an envelope could be transplanted between two events sharing a key
and would decrypt cleanly. AAD would be the natural home for this, but no released Crystal
exposes an AAD setter.

### Application keys from the environment, several at once

`ES::ApplicationKeyRing` reads `ES_APPLICATION_KEYS` / `ES_APPLICATION_KEY_CURRENT`.
Holding several keys is what makes rotation possible: new data keys wrap under the current
one, older ones still unwrap under the id recorded on their row, and `rewrap_all` migrates
them without touching an event.

Data key rotation is deliberately not offered — it would mean rewriting the event store.

### Caching

Unwrapping per event would be a keystore round trip per event, and a network call once the
ring is KMS-backed. Hydrating one aggregate hits the same key repeatedly, so `ES::Encryption`
holds a bounded, oldest-first cache of unwrapped keys. The cost — plaintext key material in
process memory — is the reason it is bounded and documented.

---

## Blast radius

| Area | Impact |
|---|---|
| `eventstore.events` schema | none |
| `eventstore_flattened` view | none — body passes through |
| pgmq queue | none — the trigger sends `NEW.header` only (`src/adapters/queues/postgres.cr:23`) |
| `bus.publish` | none — the in-memory event keeps its plaintext body |
| Existing plaintext events | none — `__es` discriminator |
| SQL against `body->>'field'` | breaks for encrypted events (none in the library today) |
| Projections | hold plaintext by design; rebuilt independently |

## Fixed along the way

`ES::Aggregate#hydrate` never compiled. `aggregate.cr:65` referenced `@event_handlers`,
declared only in a comment on line 40; Crystal typechecks only called methods and no spec
exercised `hydrate`, so it went unnoticed. Any aggregate following the README — which does
not show the parameter — would have failed to build. The registry is now a nilable ivar
resolved lazily from `ES::Config`, so existing subclasses keep working either way, and
`hydrate` has spec coverage.

The stored-row-to-event conversion was also duplicated across `aggregate.cr` and two sites
in `projection.cr`; it is now `ES::EventHandlers#materialize`, which is where the shredded
guard lives.
