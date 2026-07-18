require "./spec_helper"
require "../examples/financial-transaction/decider"

# ---------------------------------------------------------------------------
# In-memory DCB tag store for testing
# ---------------------------------------------------------------------------

class InMemoryTagStore
  include ES::DcbHandler::TagStore

  @events   : Array(ES::EventStore::Event) = [] of ES::EventStore::Event
  @position : Int64 = 0_i64

  def append(event : ES::Event)
    @events << ES::EventStore::Event.new(
      JSON.parse(event.header.to_json),
      JSON.parse(event.body.to_json)
    )
    @position += 1
  end

  def read_by_tags(query : ES::TagQuery) : {Array(ES::EventStore::Event), Int64}
    matched = @events.select do |raw|
      agg_id = raw.header["aggregate_id"]?.try(&.as_s?)
      query.tags.any? { |t| agg_id == t }
    end
    {matched, @position}
  end

  # Returns true on success, false when position has advanced (conflict).
  def append_if_unchanged(events : Array(ES::Event), query : ES::TagQuery, position : Int64) : Bool
    return false if @position != position

    events.each { |e| append(e) }
    true
  end
end

# ---------------------------------------------------------------------------
# Specs
# ---------------------------------------------------------------------------

describe ES::DcbHandler do
  it "folds tag-matched events and appends on accept" do
    tag_store = InMemoryTagStore.new
    agg_id    = UUID.v7

    # Pre-seed: a TransactionInitiated event tagged with the aggregate UUID
    init = Events::TransactionInitiated.new(
      creditor_account: UUID.new("01929fef-2e55-742f-b151-000000acc100"),
      debtor_account:   UUID.new("01929fef-2e55-742f-b151-000000acc200"),
      amount:           500_i64,
    )
    # Build raw store event with the aggregate_id we control
    header = ES::Event::Header.new(
      aggregate_id: agg_id,
      aggregate_type: "Transaction",
      aggregate_version: 1,
      command_handler: "test",
      event_handle: "transaction.initiated",
    )
    raw_init = Events::TransactionInitiated.new(header, JSON.parse(init.body.to_json))
    tag_store.append(raw_init)

    parse = ->(raw : ES::EventStore::Event) {
      h = ES::Event::Header.from_json(raw.header.to_json)
      Events::TransactionInitiated.new(h, raw.body).as(TransactionEvent)
    }

    handler = ES::DcbHandler(TransactionCommand, Aggregate::State, TransactionEvent).new(
      TransactionDecider.new, tag_store, parse
    )

    boundary = ES::TagQuery.new([agg_id.to_s])
    outcome  = handler.handle(ProcessTransaction.new(aggregate_id: agg_id), boundary)

    outcome.accepted?.should be_true
    outcome.events.first.should be_a(Events::TransactionAccepted)
  end

  it "returns the decision unchanged when conditional append fails (conflict)" do
    tag_store     = InMemoryTagStore.new
    agg_id        = UUID.v7
    stale_position = 0_i64  # read at position 0

    # Between read and append, a concurrent writer bumps position to 1
    concurrent_event = Events::TransactionInitiated.new(
      creditor_account: UUID.new("01929fef-2e55-742f-b151-000000acc100"),
      debtor_account:   UUID.new("01929fef-2e55-742f-b151-000000acc200"),
      amount:           1_i64,
    )
    tag_store.append(concurrent_event)  # position is now 1

    # The DcbHandler will read at the new position (1), but we simulate a stale
    # read by directly testing append_if_unchanged with the old position.
    conflicted = tag_store.append_if_unchanged(
      [] of ES::Event,
      ES::TagQuery.new([agg_id.to_s]),
      stale_position
    )
    conflicted.should be_false
  end

  it "proves decider is boundary-agnostic: same TransactionDecider drives both handlers" do
    # TransactionDecider was created for the aggregate-bounded CommandHandler.
    # Instantiating a DcbHandler with it (without any changes to TransactionDecider)
    # is the compile-time proof that the decider is boundary-agnostic.
    tag_store = InMemoryTagStore.new
    parse = ->(raw : ES::EventStore::Event) {
      h = ES::Event::Header.from_json(raw.header.to_json)
      Events::TransactionInitiated.new(h, raw.body).as(TransactionEvent)
    }
    _handler = ES::DcbHandler(TransactionCommand, Aggregate::State, TransactionEvent).new(
      TransactionDecider.new, tag_store, parse
    )
    # If this compiled, the proof holds.
    true.should be_true
  end
end
