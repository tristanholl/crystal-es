# AGENTS.md

Guidelines for AI coding agents working on crystal-es, a Crystal event-sourcing shard optimized for PostgreSQL. Applications depend on its public API, and their databases hold events, keys and queue state written by older versions. Treat both as contracts.

## Layout

```
src/
  crystal-es.cr          # entry point, ES::VERSION
  load.cr                # every require, in dependency order — add new files here
  config.cr              # ES::Config, the global wiring
  components/            # events, DSLs, aggregates, projections, encryption, tags, queries
  adapters/
    eventstores/         # ES::EventStore base + Postgres + InMemory
    keystores/           # ES::KeyStore base + Postgres + InMemory
    queues/              # ES::Queue base + Postgres (pgmq) + InMemory
  exceptions/            # ES::Exception::* — one class per file
spec/                    # mirrors src/; spec_helper.cr holds shared test events
examples/                # runnable example applications; keep them compiling
.claude/agents/          # compat-reviewer, security-reviewer
```

## Commands

- `crystal spec`: runs the suite locally. Run `shards install` first.
- `ES_TEST_DATABASE_URL=postgres://postgres@localhost:5432/es_test crystal spec`: also runs the specs that need a live Postgres. Without the variable they're `pending`. A throwaway database works: `docker run -d --rm -e POSTGRES_HOST_AUTH_METHOD=trust -p 127.0.0.1:55432:5432 postgres:18`.
- `crystal tool format` and `./bin/ameba` (build it with `shards build ameba`): both must be clean. CI runs `make lint` and `make test` in Docker.
- `crystal build --no-codegen examples/<name>/example.cr`: checks an example still compiles after an API change.

The compiler floor is `crystal: '>= 1.14.0'` (`shard.yml`). Don't use stdlib APIs or macro features newer than that. If unsure, compile against `crystallang/crystal:1.14.0` in Docker. Ameba itself needs a newer Crystal, which only matters for development.

## Invariants

- **Events are immutable history.** `eventstore.events` is append-only: no `UPDATE`, `DELETE` or `TRUNCATE`, and no rewriting order. Every event already stored, from any past release, must still deserialize. New `Event::Header` fields need defaults, and should not be serialized when empty if that keeps old JSON unchanged.
- **The encryption format is frozen.** Existing ciphertexts must keep decrypting: the cipher, subkey labels, envelope layout and `binding_digest` input. Keys derived from the application key go through `derive_key`, which separates them from the key-wrapping subkeys.
- **`setup` is idempotent and also runs on existing stores.** An existing store takes the early-return branch, so anything new (an index, for example) must be applied there too, with `IF NOT EXISTS`. Mind that index builds block writes on large tables.
- **Projection schemas are immutable.** Schema drift raises; there's no in-place migration.
- **Adapter parity.** Every event store feature exists in both the Postgres and in-memory adapters, with the same semantics. Write the specs as shared scenarios run against both (see `spec/adapters/eventstores/read_query_spec.cr`).
- **Tag versions.** Every tagged append must raise the version of each of its tags under the row lock in `eventstore.tag_versions`, and stamp it into the stored header (`append_batch` in `src/adapters/eventstores/postgres.cr`). Header tags and raised versions both come from `stored_tags`. A write path that skips this breaks conditional appends silently. Consistency must never rest on positions, which aren't commit-ordered.

## Code conventions

- **Fail loudly.** Refuse an unsafe or ambiguous state with an `ES::Exception::*` rather than degrading silently. For example: never store something in the clear that was declared encrypted or hashed, and never return a silently short result.
- **Prefer compile-time checks** for DSLs (`define_event`, `define_projection`): validate in the macro and `raise` with a precise message. Cover each error with a subprocess compile spec (see `spec/components/event_tags_compile_spec.cr`). Write compile-time warnings with `{% warning %}`.
- **Comments explain why**, not what. Public API gets doc comments with a usage example.
- **SQL:** only fixed fragments and `$n` placeholders; values always travel as parameters. A `%(...)` literal counts parentheses, so use a plain string for SQL with unbalanced ones.
- **Secrets and personal data:** keys, plaintext bodies and the values of hashed tags never reach logs, exception messages, `to_s`/`inspect` or the plaintext header. Override `inspect`/`to_s` on anything holding key material.
- **The library never reads the environment or creates Postgres extensions.** Configuration comes in through constructors and `ES::Config`.
- Ameba rules in force include no `not_nil!` and no single-letter block parameters. `.ameba.yml` documents every exemption with its reason.

## Compatibility and releases

- The project is pre-1.0 SemVer: a breaking change needs a minor bump, while additive changes and fixes take a patch. `version:` in `shard.yml` and `ES::VERSION` in `src/crystal-es.cr` must agree.
- Record every release in `CHANGELOG.md`, with upgrade notes for anything an existing application or database has to act on.
- New methods on base classes that users subclass (`ES::EventStore`, `ES::KeyStore`, `ES::Queue`) get a non-abstract default that raises `ES::Exception::NotImplemented`. A new `abstract def` breaks every third-party adapter.
- Changing a return type, a raised exception class or a constructor default is breaking, even when it looks harmless.

## Workflow

- After every code change, and before committing, run the **compat-reviewer** and **security-reviewer** agents in `.claude/agents/`. Both are read-only and report findings; act on them or explain why not.
- Concurrency and locking specs must show they can fail: temporarily remove the mechanism under test and confirm the spec fails before relying on it. Racing fibers need their connections opened up front, otherwise connection setup serializes them.
- Never attribute work to an AI tool in commits, pull requests, issues or review comments: no `Co-Authored-By` trailer for an assistant, and no "Generated with …" line.
- Keep the README in step with behaviour. It documents guarantees as well as limits, such as what encryption and hashing don't protect.
