require "../spec_helper"

class DummyAggregate < ES::Aggregate
  @@type = "DummyAggregate"

  struct State < ES::Aggregate::State; end

  # Initialize the aggregate
  # - with aggregate_id
  # - with event_store
  def initialize(
    aggregate_id : UUID,
    @event_store : ES::EventStore,
    @reject_unhandled_events = true
  )
    @state = State.new(aggregate_id)
    @state.set_type(@@type)
  end

  def state : State
    @state
  end
end

describe ES::Aggregate do
  it "class returns the aggregate type" do
    DummyAggregate.type.should eq("DummyAggregate")
  end

  it "increases the aggregate version for unhandled event for non-strict stream handling" do
    store = ES::EventStoreAdapters::InMemory.new
    dummyEvent = DummyEvent.new
    aggregate_id = dummyEvent.header.aggregate_id

    aggr = DummyAggregate.new(aggregate_id, store, reject_unhandled_events: false)

    aggr.apply(dummyEvent)

    aggr.state.version.should eq(1)
  end

  it "fails to apply the same event twice" do
    store = ES::EventStoreAdapters::InMemory.new
    dummyEvent = DummyEvent.new
    aggregate_id = dummyEvent.header.aggregate_id

    aggr = DummyAggregate.new(aggregate_id, store, reject_unhandled_events: false)

    aggr.apply(dummyEvent)

    expect_raises(ES::Exception::InvalidState) do
      aggr.apply(dummyEvent)
    end
  end

  it "raises an exception unhandled event for strict stream handling" do
    store = ES::EventStoreAdapters::InMemory.new
    dummyEvent = DummyEvent.new
    aggregate_id = dummyEvent.header.aggregate_id

    aggr = DummyAggregate.new(aggregate_id, store, reject_unhandled_events: true)

    expect_raises(ES::Exception::InvalidEventStream) do
      aggr.apply(dummyEvent)
    end
  end
end
