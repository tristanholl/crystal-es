# Migration Notes — Decider + Command/Handler Migration

## Baseline spec count

Run `make test` before any phase change to capture the count. Record it here.
Estimated current count: see CI output.

## Inventory

### ES::Command subclasses

| Class | File | Notes |
|-------|------|-------|
| `DummyCommand` | `spec/spec_helper.cr` | Test double — migrate last (Phase 5) |
| `IncompleteDummyCommand` | `spec/components/command_spec.cr` | Test double for NotImplemented spec |
| `Commands::ProcessTransaction` | `examples/financial-transaction/commands/process_transaction.cr` | Reference migration target for Phase 4 |

### ES::Aggregate subclasses

| Class | File | Notes |
|-------|------|-------|
| `DummyAggregate` | `spec/components/aggregate_spec.cr` | Test double — no decider needed |
| `Aggregate` | `examples/financial-transaction/aggregate.cr` | Reference migration target for Phase 4 |

## Phase checklist

- [x] Phase 0 — Baseline inventory and e2e anchor spec
- [x] Phase 1 — `ES::Decision(E)` result type
- [x] Phase 2 — `ES::Decider(C,S,E)` module + pure `evolve` / `fold`
- [x] Phase 3 — Generic `ES::CommandHandler(C,S,E)`
- [x] Phase 4 — Migrate `financial-transaction` aggregate (reference migration)
- [ ] Phase 5 — Migrate remaining aggregates, retire `ES::Command#call`
- [ ] Phase 6 — DCB-ready handler (additive, deferred until tag store work)

## Breaking-change boundary

Phase 5 is the first release with breaking changes.  
New minor version: `0.7.0`.

## Invariants checked at every phase boundary

1. `make test` green; spec count only grows.
2. `evolve` and `decide` never reference the event store.
3. No decider references a concrete event store or queue.
4. The `spec/financial_transaction_e2e_spec.cr` assertions are byte-for-byte identical.
