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
    @reject_unhandled_events = true,
  )
    @state = State.new(aggregate_id)
    @state.set_type(@@type)
  end

  def state : State
    @state
  end
end

# Shaped like examples/financial-transaction/aggregate.cr: a subclass that takes
# the registry in its own constructor and declares it non-nilable. The base class
# holds it as nilable so subclasses like DummyAggregate above need not supply one
# at all, and this guards the combination.
class HydratingAggregate < ES::Aggregate
  @@type = "HydratingAggregate"

  struct State < ES::Aggregate::State
    property comments : Array(String) = [] of String
  end

  getter state : State

  def initialize(
    aggregate_id : UUID,
    @event_store : ES::EventStore = ES::Config.event_store,
    @event_handlers : ES::EventHandlers = ES::Config.event_handlers,
  )
    @state = State.new(aggregate_id)
    @state.set_type(@@type)
  end

  def apply(event : PlainEvent)
    @state.increase_version(event.header.aggregate_version)
    @state.comments << event.body.as(PlainEvent::Body).secret
  end
end

describe ES::Aggregate do
  it "class returns the aggregate type" do
    DummyAggregate.type.should eq("DummyAggregate")
  end

  describe "#hydrate" do
    it "replays a stored stream back into state" do
      store = ES::EventStoreAdapters::InMemory.new
      aggregate_id = UUID.v7

      store.append(PlainEvent.new(
        actor_id: nil, command_handler: "handler", aggregate_id: aggregate_id,
        aggregate_version: 1, secret: "first"
      ))
      store.append(PlainEvent.new(
        actor_id: nil, command_handler: "handler", aggregate_id: aggregate_id,
        aggregate_version: 2, secret: "second"
      ))

      aggregate = HydratingAggregate.new(aggregate_id, store, test_event_handlers)
      aggregate.hydrate

      aggregate.state.comments.should eq(["first", "second"])
      aggregate.state.version.should eq(2)
    end

    it "stops at the requested version" do
      store = ES::EventStoreAdapters::InMemory.new
      aggregate_id = UUID.v7

      store.append(PlainEvent.new(
        actor_id: nil, command_handler: "handler", aggregate_id: aggregate_id,
        aggregate_version: 1, secret: "first"
      ))
      store.append(PlainEvent.new(
        actor_id: nil, command_handler: "handler", aggregate_id: aggregate_id,
        aggregate_version: 2, secret: "second"
      ))

      aggregate = HydratingAggregate.new(aggregate_id, store, test_event_handlers)
      aggregate.hydrate(version: 1)

      aggregate.state.comments.should eq(["first"])
      aggregate.state.version.should eq(1)
    end

    it "raises when the aggregate has no events" do
      aggregate = HydratingAggregate.new(UUID.v7, ES::EventStoreAdapters::InMemory.new, test_event_handlers)

      expect_raises(ES::Exception::NotFound) do
        aggregate.hydrate
      end
    end
  end

  it "increases the aggregate version for unhandled event for non-strict stream handling" do
    store = ES::EventStoreAdapters::InMemory.new
    dummy_event = DummyEvent.new
    aggregate_id = dummy_event.header.aggregate_id

    aggr = DummyAggregate.new(aggregate_id, store, reject_unhandled_events: false)

    aggr.apply(dummy_event)

    aggr.state.version.should eq(1)
  end

  it "fails to apply the same event twice" do
    store = ES::EventStoreAdapters::InMemory.new
    dummy_event = DummyEvent.new
    aggregate_id = dummy_event.header.aggregate_id

    aggr = DummyAggregate.new(aggregate_id, store, reject_unhandled_events: false)

    aggr.apply(dummy_event)

    expect_raises(ES::Exception::InvalidState) do
      aggr.apply(dummy_event)
    end
  end

  it "raises an exception unhandled event for strict stream handling" do
    store = ES::EventStoreAdapters::InMemory.new
    dummy_event = DummyEvent.new
    aggregate_id = dummy_event.header.aggregate_id

    aggr = DummyAggregate.new(aggregate_id, store, reject_unhandled_events: true)

    expect_raises(ES::Exception::InvalidEventStream) do
      aggr.apply(dummy_event)
    end
  end
end
