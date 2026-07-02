require "../spec_helper"

class BoundaryTestEvent < ES::Event
  include ::ES::EventDSL

  define_event "BoundaryTestAggregate", "boundary.test.event" do
    attribute :amount, Int32, 0
  end
end

class BoundaryTestAggregate < ES::Aggregate
  @@type = "BoundaryTestAggregate"

  struct State < ES::Aggregate::State
    property total : Int32 = 0
  end

  getter state : State

  def initialize(
    aggregate_id : UUID,
    @event_store : ES::EventStore,
    @event_handlers : ES::EventHandlers,
  )
    @state = State.new(aggregate_id)
    @state.set_type(@@type)
  end

  def apply(event : BoundaryTestEvent)
    @state.increase_version(event.header.aggregate_version)

    @state.total += event.body.as(BoundaryTestEvent::Body).amount
  end
end

private def boundary_setup
  store = ES::EventStoreAdapters::InMemory.new
  handlers = ES::EventHandlers.new
  handlers.register(BoundaryTestEvent)

  {store, handlers}
end

describe ES::Boundary do
  it "loads an aggregate and captures its version in the condition" do
    store, handlers = boundary_setup
    aggregate_id = UUID.v7
    store.append(BoundaryTestEvent.new(actor_id: nil, command_handler: "test", aggregate_id: aggregate_id, aggregate_version: 1, amount: 5))

    boundary = ES::Boundary.new(store)
    aggregate = boundary.load(BoundaryTestAggregate.new(aggregate_id, store, handlers))

    aggregate.state.total.should eq(5)
    boundary.next_version(aggregate).should eq(2)
  end

  it "loads an aggregate without events at version 0" do
    store, handlers = boundary_setup

    boundary = ES::Boundary.new(store)
    aggregate = boundary.load(BoundaryTestAggregate.new(UUID.v7, store, handlers))

    aggregate.state.version.should eq(0)
    boundary.next_version(aggregate).should eq(1)
  end

  it "folds a tag stream and captures the tag version" do
    store, _ = boundary_setup
    tag = "course:#{UUID.v7}"
    store.append(BoundaryTestEvent.new(actor_id: nil, command_handler: "test", aggregate_version: 1, tags: {tag => 1}))
    store.append(BoundaryTestEvent.new(actor_id: nil, command_handler: "test", aggregate_version: 1, tags: {tag => 2}))

    boundary = ES::Boundary.new(store)
    count = 0
    boundary.load(tag) { |_event| count += 1 }

    count.should eq(2)
    boundary.next_version(tag).should eq(3)
  end

  it "commits staged events atomically" do
    store, handlers = boundary_setup
    aggregate_id = UUID.v7
    tag = "course:#{UUID.v7}"

    boundary = ES::Boundary.new(store)
    aggregate = boundary.load(BoundaryTestAggregate.new(aggregate_id, store, handlers))
    boundary.load(tag) { }

    boundary.stage(BoundaryTestEvent.new(
      actor_id: nil,
      command_handler: "test",
      aggregate_id: aggregate_id,
      aggregate_version: boundary.next_version(aggregate),
      tags: {tag => boundary.next_version(tag)},
      amount: 5
    ))
    boundary.commit

    store.last_version(aggregate_id.to_s).should eq(1)
    store.last_version(tag).should eq(1)
  end

  it "accounts for staged events when computing the next version" do
    store, handlers = boundary_setup
    aggregate_id = UUID.v7

    boundary = ES::Boundary.new(store)
    aggregate = boundary.load(BoundaryTestAggregate.new(aggregate_id, store, handlers))

    boundary.next_version(aggregate).should eq(1)
    boundary.stage(BoundaryTestEvent.new(actor_id: nil, command_handler: "test", aggregate_id: aggregate_id, aggregate_version: 1))
    boundary.next_version(aggregate).should eq(2)
    boundary.stage(BoundaryTestEvent.new(actor_id: nil, command_handler: "test", aggregate_id: aggregate_id, aggregate_version: 2))
    boundary.next_version(aggregate).should eq(3)
  end

  it "raises a conflict when a loaded sequence advanced between load and commit" do
    store, handlers = boundary_setup
    tag = "course:#{UUID.v7}"

    boundary = ES::Boundary.new(store)
    boundary.load(tag) { }

    # A competing writer advances the tag sequence after the boundary was built
    store.append(BoundaryTestEvent.new(actor_id: nil, command_handler: "test", aggregate_version: 1, tags: {tag => 1}))

    boundary.stage(BoundaryTestEvent.new(actor_id: nil, command_handler: "test", aggregate_version: 1))
    expect_raises(ES::Exception::Conflict) do
      boundary.commit
    end
  end

  it "raises a conflict when a read-only tracked sequence advanced" do
    store, handlers = boundary_setup
    tag = "course:#{UUID.v7}"
    store.append(BoundaryTestEvent.new(actor_id: nil, command_handler: "test", aggregate_version: 1, tags: {tag => 1}))

    boundary = ES::Boundary.new(store)
    boundary.track(tag, 1)

    store.append(BoundaryTestEvent.new(actor_id: nil, command_handler: "test", aggregate_version: 1, tags: {tag => 2}))

    boundary.stage(BoundaryTestEvent.new(actor_id: nil, command_handler: "test", aggregate_version: 1))
    expect_raises(ES::Exception::Conflict) do
      boundary.commit
    end
  end

  it "can be reused after a successful commit" do
    store, handlers = boundary_setup
    aggregate_id = UUID.v7

    boundary = ES::Boundary.new(store)
    aggregate = boundary.load(BoundaryTestAggregate.new(aggregate_id, store, handlers))

    boundary.stage(BoundaryTestEvent.new(actor_id: nil, command_handler: "test", aggregate_id: aggregate_id, aggregate_version: boundary.next_version(aggregate)))
    boundary.commit

    boundary.stage(BoundaryTestEvent.new(actor_id: nil, command_handler: "test", aggregate_id: aggregate_id, aggregate_version: boundary.next_version(aggregate_id.to_s)))
    boundary.commit

    store.last_version(aggregate_id.to_s).should eq(2)
  end
end
