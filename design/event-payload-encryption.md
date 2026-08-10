# Design: Event Payload Encryption

Status: **implemented**, deliberately scoped down for a first iteration. This records
the reasoning; `README.md` documents the API.

## Goal

Crypto-shredding. An event store is immutable, so once personal data lands in a body
there is no way to erase it — which leaves an erasure request unanswerable short of
rewriting history. Encrypting the body under a key that can be destroyed makes erasure
a `DELETE` of one row instead.

Encryption at rest is the side effect, not the driver.

## Threat model

**Protected:** event bodies in `eventstore.events` — dumps, backups, replicas, a DBA with
`SELECT`, a stolen volume — and erasure by key deletion.

**Not protected:** the event *header* (indexed, drives the flattened view, so it stays
plaintext), application memory, logs, and **projections**. A projection built from an
encrypted event stores whatever it extracted in the clear. Encryption stops at the event
store; read models are treated as temporary and rebuilt independently.

---

## Decisions

### Whole body, whole erasure, no shredding machinery

Not per-attribute, and not softened by a tombstone or a "shredded" signal. A destroyed
key is a real `DELETE FROM encryption_keys WHERE id = $1`. Reading a body that names a
deleted key raises `ES::Exception::NotFound` — the same exception a missing event row
would raise. No new exception type, no `destroyed_at`, no `EventStore::Event#shredded?`.

The deletion is the answer. Anything that must survive an erasure — a retained financial
record, an anonymised aggregate — is extracted by the application before the key goes,
and an application that wants a projection replay to keep going past an erasure rescues
`NotFound` around it. The library does not build that in.

This was a deliberate simplification from an earlier pass, which had rotation, a
tombstone-based destroy, and a `shredded?` signal threaded through `Aggregate#hydrate`
and `Projection#replay` with an opt-in `skip_shredded_events` flag. Reasonable, but more
than a first iteration needed, and the maintainer's call was to cut it: "the deletion
should be good enough."

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

### Symmetric, not asymmetric

An earlier sketch of the key table used `"encryption_algorithm": "ES256"`. ES256 is
ECDSA — a *signing* algorithm, not an encryption one, so it could not have done this job
regardless of preference. Asymmetric encryption (ECIES, RSA-OAEP) earns its cost only
when the party encrypting shouldn't be able to decrypt; here the same application does
both, so there's no separation of duty to protect. AES-256 stays, and
`encryption_algorithm` records the real cipher name.

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

### One application key, passed in — never read from the environment

`ES::ApplicationEncryptionKeyManager` takes its key as raw bytes through the
constructor and does not touch `ENV` itself. This is a library; deciding where a
secret comes from — an environment variable, a mounted file, a KMS call — is an
application concern, not something the library should assume. The application reads
`APPLICATION_ENCRYPTION_KEYS` (or wherever it keeps the key) and passes the decoded
bytes in:

```crystal
ES::ApplicationEncryptionKeyManager.new(Base64.decode(ENV["APPLICATION_ENCRYPTION_KEYS"]))
```

`application_encryption_key_id` on each key row is `Digest::SHA256.hexdigest` of that
key's bytes, not an operator-assigned name — so it's always correct for whatever key
is actually loaded, and a key row wrapped under a different key on a misconfigured
environment fails the id check in `unwrap` rather than decrypting into garbage.

No rotation. Changing the application key makes every existing data key unwrappable, so
it is effectively fixed for the store's lifetime in this iteration. A ring holding
several application keys at once — the natural way to support rotation without downtime
— is a reasonable follow-up, deliberately deferred.

Data key rotation is also not offered — it would mean rewriting the event store.

### No cache

Every `open`/`seal` does one `KeyStore#fetch` plus one symmetric unwrap. Without a cache,
hydrating an aggregate with several events under the same key does one fetch per event
rather than one per unique key — a real cost on long streams. Traded away for this
iteration in the same simplification pass; it can be reintroduced later inside
`EncryptionKeyManager#open`/`#seal` without changing the on-disk format or any public
signature.

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

`ES::Aggregate#hydrate` never compiled. `aggregate.cr` referenced `@event_handlers`,
declared only in a comment; Crystal typechecks only called methods and no spec exercised
`hydrate`, so it went unnoticed. Any aggregate following the README — which does not show
the parameter — would have failed to build. The registry is now a nilable ivar resolved
lazily from `ES::Config`, so existing subclasses keep working either way, and `hydrate`
has spec coverage.

The stored-row-to-event conversion was also duplicated across `aggregate.cr` and two
sites in `projection.cr`; it is now `ES::EventHandlers#materialize`.
