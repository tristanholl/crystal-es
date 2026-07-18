require "./spec_helper"
require "../examples/financial-transaction/decider"

# Anchor spec — the assertions below (event types, amounts, aggregate versions,
# and aggregate IDs) must remain byte-for-byte identical through Phase 6.
# Only the dispatch mechanism changes between phases.

describe "financial-transaction e2e" do
  def build_infra
    store         = ES::EventStoreAdapters::InMemory.new
    event_handlers = ES::EventHandlers.new
    event_handlers.register(Events::TransactionInitiated)
    event_handlers.register(Events::TransactionAccepted)
    event_handlers.register(Events::TransactionRejected)
    {store, event_handlers}
  end

  def parse_event(raw : ES::EventStore::Event, event_handlers : ES::EventHandlers) : ES::Event
    h = ES::Event::Header.from_json(raw.header.to_json)
    event_handlers.event_class(h.event_handle).new(h, raw.body)
  end

  it "accepts a transaction at or below the 1000 limit" do
    store, event_handlers = build_infra
    handler = build_transaction_handler(store, event_handlers)

    init = Events::TransactionInitiated.new(
      creditor_account: UUID.new("01929fef-2e55-742f-b151-000000acc100"),
      debtor_account:   UUID.new("01929fef-2e55-742f-b151-000000acc200"),
      amount:           500_i64,
    )
    store.append(init)
    aggregate_id = init.header.aggregate_id

    handler.handle(aggregate_id, ProcessTransaction.new(aggregate_id: aggregate_id))

    events = store.fetch_events(aggregate_id)
    events.size.should eq(2)

    first = parse_event(events[0], event_handlers)
    first.should be_a(Events::TransactionInitiated)
    first.body.as(Events::TransactionInitiated::Body).amount.should eq(500_i64)

    second = parse_event(events[1], event_handlers)
    second.should be_a(Events::TransactionAccepted)
    second.header.aggregate_version.should eq(2)
    second.header.aggregate_id.should eq(aggregate_id)
  end

  it "rejects a transaction above the 1000 limit" do
    store, event_handlers = build_infra
    handler = build_transaction_handler(store, event_handlers)

    init = Events::TransactionInitiated.new(
      creditor_account: UUID.new("01929fef-2e55-742f-b151-000000acc100"),
      debtor_account:   UUID.new("01929fef-2e55-742f-b151-000000acc200"),
      amount:           1500_i64,
    )
    store.append(init)
    aggregate_id = init.header.aggregate_id

    handler.handle(aggregate_id, ProcessTransaction.new(aggregate_id: aggregate_id))

    events = store.fetch_events(aggregate_id)
    events.size.should eq(2)

    first = parse_event(events[0], event_handlers)
    first.should be_a(Events::TransactionInitiated)

    second = parse_event(events[1], event_handlers)
    second.should be_a(Events::TransactionRejected)
    second.header.aggregate_version.should eq(2)
    second.header.aggregate_id.should eq(aggregate_id)
    second.body.as(Events::TransactionRejected::Body).reason.should contain("1500")
  end

  it "is idempotent when transaction is already settled" do
    store, event_handlers = build_infra
    handler = build_transaction_handler(store, event_handlers)

    init = Events::TransactionInitiated.new(
      creditor_account: UUID.new("01929fef-2e55-742f-b151-000000acc100"),
      debtor_account:   UUID.new("01929fef-2e55-742f-b151-000000acc200"),
      amount:           100_i64,
    )
    store.append(init)
    aggregate_id = init.header.aggregate_id

    # First handle: accepts and appends
    handler.handle(aggregate_id, ProcessTransaction.new(aggregate_id: aggregate_id))
    # Second handle: already settled → Decision.reject, no append
    outcome = handler.handle(aggregate_id, ProcessTransaction.new(aggregate_id: aggregate_id))

    outcome.rejected?.should be_true
    store.fetch_events(aggregate_id).size.should eq(2)
  end
end
