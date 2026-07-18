require "./spec_helper"

# ---------------------------------------------------------------------------
# Minimal fixtures — all scoped to this spec to avoid naming conflicts.
# ---------------------------------------------------------------------------

struct EvTestState < ES::Aggregate::State
  property count : Int32 = 0

  def initialize(@aggregate_id : UUID)
    @aggregate_type = "EvTest"
    @aggregate_version = 0
  end
end

class EvTestEvent < ES::Event
  @@handle = "evtest.counted"

  struct Body < ES::Event::Body
    include JSON::Serializable

    def initialize(@comment = ""); end
  end

  def initialize(@header : ES::Event::Header, body : JSON::Any)
    @body = Body.from_json(body.to_json)
  end

  def initialize(version : Int32, aggregate_id : UUID = UUID.v7)
    @header = Header.new(
      aggregate_id: aggregate_id,
      aggregate_type: "EvTest",
      aggregate_version: version,
      command_handler: "test",
      event_handle: @@handle
    )
    @body = Body.new
  end
end

class EvTestDecider
  include ES::Decider(Nil, EvTestState, EvTestEvent)

  def initial_state : EvTestState
    EvTestState.new(UUID.v7)
  end

  def decide(command : Nil, state : EvTestState) : ES::Decision(EvTestEvent)
    ES::Decision(EvTestEvent).accept([] of EvTestEvent)
  end

  def evolve(state : EvTestState, event : EvTestEvent) : EvTestState
    state.count += 1
    state.aggregate_version = event.header.aggregate_version
    state
  end
end

# ---------------------------------------------------------------------------
# Specs
# ---------------------------------------------------------------------------

describe "ES::Decider#fold" do
  it "folds zero events and returns the starting state unchanged" do
    dec = EvTestDecider.new
    s = dec.initial_state
    s.count = 7
    result = dec.fold(s, [] of EvTestEvent)
    result.count.should eq(7)
  end

  it "folds events from initial state (version 0 → 1 → 2 → 3)" do
    agg_id = UUID.v7
    dec = EvTestDecider.new
    events = [
      EvTestEvent.new(version: 1, aggregate_id: agg_id),
      EvTestEvent.new(version: 2, aggregate_id: agg_id),
      EvTestEvent.new(version: 3, aggregate_id: agg_id),
    ]
    result = dec.fold(dec.initial_state, events)
    result.count.should eq(3)
    result.aggregate_version.should eq(3)
  end

  it "folds a partial slice starting from a non-initial state" do
    # This is the key invariant: fold is NOT coupled to start-from-zero.
    # Starting from count=5, version=4, and applying two more events
    # must yield count=7, version=6 — without assuming a full stream.
    agg_id = UUID.v7
    dec = EvTestDecider.new

    base = dec.initial_state
    base.count = 5
    base.aggregate_version = 4

    events = [
      EvTestEvent.new(version: 5, aggregate_id: agg_id),
      EvTestEvent.new(version: 6, aggregate_id: agg_id),
    ]

    result = dec.fold(base, events)
    result.count.should eq(7)
    result.aggregate_version.should eq(6)
  end

  it "fold result is independent of the original state reference" do
    dec = EvTestDecider.new
    original = dec.initial_state
    original.count = 10

    result = dec.fold(original, [EvTestEvent.new(version: 1)])
    result.count.should eq(11)
    # original is a struct (value type) — the fold must not mutate the
    # argument that was passed in; each step works on a fresh copy.
    original.count.should eq(10)
  end
end
