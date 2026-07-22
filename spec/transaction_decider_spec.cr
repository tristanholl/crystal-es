require "./spec_helper"
require "../examples/financial-transaction/decider"

# ---------------------------------------------------------------------------
# Pure decider tests — no event store involved.
# All assertions use ES::Decision equality (value comparison).
# ---------------------------------------------------------------------------

describe TransactionDecider do
  let(:decider) { TransactionDecider.new }
  let(:agg_id) { UUID.v7 }

  def make_state_after_initiation(agg_id : UUID, amount : Int64) : Aggregate::State
    init_event = Events::TransactionInitiated.new(
      creditor_account: UUID.new("01929fef-2e55-742f-b151-000000acc100"),
      debtor_account: UUID.new("01929fef-2e55-742f-b151-000000acc200"),
      amount: amount,
    )
    # Manually build header with the specific aggregate_id so state tracks it
    header = ES::Event::Header.new(
      aggregate_id: agg_id,
      aggregate_type: "Transaction",
      aggregate_version: 1,
      command_handler: "test",
      event_handle: "transaction.initiated",
    )
    typed = Events::TransactionInitiated.new(header, JSON.parse(init_event.body.to_json))
    TransactionDecider.new.evolve(
      begin
        s = Aggregate::State.new(agg_id)
        s.set_type("Transaction")
        s
      end,
      typed
    )
  end

  it "accepts a transaction at or below the 1000 limit" do
    state = make_state_after_initiation(agg_id, 500_i64)
    cmd   = ProcessTransaction.new(aggregate_id: agg_id)

    outcome = decider.decide(cmd, state)

    outcome.accepted?.should be_true
    outcome.events.size.should eq(1)
    outcome.events.first.should be_a(Events::TransactionAccepted)
    outcome.events.first.header.aggregate_id.should eq(agg_id)
    outcome.events.first.header.aggregate_version.should eq(2)
  end

  it "accepts exactly at the 1000 boundary" do
    state = make_state_after_initiation(agg_id, 1000_i64)
    cmd   = ProcessTransaction.new(aggregate_id: agg_id)

    outcome = decider.decide(cmd, state)

    outcome.accepted?.should be_true
    outcome.events.first.should be_a(Events::TransactionAccepted)
  end

  it "rejects a transaction above the 1000 limit" do
    state = make_state_after_initiation(agg_id, 1001_i64)
    cmd   = ProcessTransaction.new(aggregate_id: agg_id)

    outcome = decider.decide(cmd, state)

    outcome.accepted?.should be_true   # decision is "accepted" — we DO append an event
    outcome.events.size.should eq(1)
    outcome.events.first.should be_a(Events::TransactionRejected)
    outcome.events.first.as(Events::TransactionRejected).body
      .as(Events::TransactionRejected::Body).reason.should contain("1001")
  end

  it "rejects already-accepted transactions" do
    state = make_state_after_initiation(agg_id, 100_i64)
    # Apply an accepted event to state
    accepted_ev = Events::TransactionAccepted.new(
      aggregate_id: agg_id,
      aggregate_version: 2,
      command_handler: "test",
    )
    settled_state = decider.evolve(state, accepted_ev)

    outcome = decider.decide(ProcessTransaction.new(aggregate_id: agg_id), settled_state)

    outcome.rejected?.should be_true
    outcome.reason.should eq("Transaction already settled")
  end

  it "rejects already-rejected transactions" do
    state = make_state_after_initiation(agg_id, 9999_i64)
    rejected_ev = Events::TransactionRejected.new(
      aggregate_id: agg_id,
      aggregate_version: 2,
      command_handler: "test",
      reason: "over limit",
    )
    settled_state = decider.evolve(state, rejected_ev)

    outcome = decider.decide(ProcessTransaction.new(aggregate_id: agg_id), settled_state)

    outcome.rejected?.should be_true
    outcome.reason.should eq("Transaction already settled")
  end

  it "two equal decisions compare equal" do
    state = make_state_after_initiation(agg_id, 500_i64)
    cmd   = ProcessTransaction.new(aggregate_id: agg_id)

    a = decider.decide(cmd, state)
    b = decider.decide(cmd, state)

    a.should eq(b)
  end

  # Compile-time proof (left as a commented-out line):
  # The following would not compile because DummyEvent is not a TransactionEvent:
  #   ES::Decision(TransactionEvent).accept([DummyEvent.new])
end
