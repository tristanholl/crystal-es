# Projections

`ES::Projection` maintains a read model by consuming events in order. It can be replayed from scratch at any time.

## Projection DSL

`define_projection` generates the full projection class — table creation, column definitions, index setup, and event handlers — from a concise block.

```crystal
class Postings < ES::Projection
  include ES::ProjectionDSL

  define_projection "ledger.postings" do
    column :id,         UUID, primary_key: true
    column :account_id, UUID
    column :amount,     Int64
    column :posted_at,  Time

    index [:account_id]
    index [:id], unique: true
  end

  # Event handlers are declared on the class, not inside the block —
  # `define_projection` reads only `column` and `index` declarations.
  apply(OrderPlaced) do
    # insert into postings table
  end
end
```

**`column(name, type, **options)`** maps Crystal types to PostgreSQL column types:

| Crystal type | PostgreSQL type |
|---|---|
| `String` | `TEXT` |
| `Int64` | `BIGINT` |
| `UUID` | `UUID` |
| `Time` | `TIMESTAMPTZ` |
| `Bool` | `BOOLEAN` |

**`index(columns, unique: false, name: nil, using: :btree, opclass: nil, where: nil, include: nil)`** — add an index to the projection table.

```crystal
index [:email]                                                                      # plain btree, auto-named users_email_idx
index ["lower(email)"], name: "users_email_lower_idx"                               # string entry = SQL expression
index [:name], using: :gin, opclass: :gin_trgm_ops, name: "instruments_name_trgm_idx"
index [:uuid], where: "status = 'open'", name: "tasks_open_uuid_idx"                # partial index
index [:status], include: [:name], name: "tasks_status_cover_idx"                   # covering index
index [:name, "lower(email)"], opclass: [:text_pattern_ops, nil], name: "users_mixed_idx"
```

- `columns`: a symbol is a column name; a string is a raw SQL expression, emitted as `(<expr>)`.
- `using:` — `:btree` (default), `:gin`, `:gist` or `:hash`.
- `opclass:` — one operator class for every entry, or an array with one entry (or `nil`) per column/expression.
- `where:` — the predicate of a partial index.
- `include:` — extra columns of a covering index (btree and gist only).
- `name:` is required when the index uses an expression, `where:` or a non-btree `using:`, since the generated name is built from column names only.

All values are compile-time literals and are checked when the projection compiles. Invalid options, an unknown `using:` or a missing `name:` are compile errors.

Operator classes from extensions need the extension installed first. For example, `gin_trgm_ops` needs `CREATE EXTENSION pg_trgm`. crystal-es doesn't create extensions, because that usually needs elevated privileges. Install them in your database image or migrations; otherwise creating the index fails when the projection boots.

**`apply(EventClass) { ... }`** — handle an event to update the read model. Declared on the class body, alongside `define_projection` rather than inside it. Within the block, `header`, `aggregate_id`, `aggregate_version`, `created_at` and `body` are pre-bound. A plain `def apply(event : EventClass)` works identically.

A projection consumes only the events it declares an `apply` for; `EventBus#subscribe` rejects a subscription to any other event. To consume everything, override the catch-all `apply(event : ES::Event)` instead.

**`define_projection(table, atomic: true)`** declares that every write of the projection goes through `write { |connection| ... }`. [Subscriptions](subscriptions.md#projections) then apply events in batches, each committed together with the projection's position.

## Schema Drift Detection

Every projection schema is **immutable**. When `setup_table` is called, the library computes a SHA-256 fingerprint of the compiled schema (columns, types, nullability, defaults, indexes) and compares it against the fingerprint stored in `_crystal_es_projection_metadata`. If they diverge, a `ES::Exception::SchemaDrift` exception is raised before the projection can run.

**Breaking changes** (raise `SchemaDrift`):
- Column added, removed, or reordered
- Column type or Crystal type changed
- Nullability or default value changed
- Primary key changed

**Non-breaking changes** (logged as a warning, metadata updated):
- Index added, removed, or modified

The error message tells you exactly what changed:

```
Schema drift detected for 'Ledger' (table: finance.ledger).
Stored fingerprint:   abc123...
Compiled fingerprint: def456...
Changes:
  breaking column_type_changed: column "amount" type changed from TEXT to BIGINT
Projection schemas are immutable. Define a new projection class with a new table
name, populate it from the event store, then rewire the application to the new projection.
```

To evolve a projection, create a new projection class targeting a new table name, replay the event store into it, then cut the application over. There is no in-place migration path — this is by design.

You can also inspect drift status without triggering an exception:

```crystal
status = Ledger.drift_status(db)
# => ES::ProjectionMeta::DriftStatus with fingerprints and list of SchemaChange objects
```
