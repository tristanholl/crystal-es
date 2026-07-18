require "./spec_helper"

# ---------------------------------------------------------------------------
# Minimal fixtures for the handler spec
# ---------------------------------------------------------------------------

# Simple command data record
record HandlerCmd, should_accept : Bool

# Simple state
struct HandlerState < ES::Aggregate::State
  property processed : Int32 = 0

  def initialize(@aggregate_id : UUID)
    @aggregate_type = "HandlerTest"
    @aggregate_version = 0
  end
end

# Simple domain event
class HandlerEvent < ES::Event
  @@handle = "handler.processed"

  struct Body < ES::Event::Body
    include JSON::Serializable

    def initialize(@comment = ""); end
  end

  def initialize(@header : ES::Event::Header, body : JSON::Any)
    @body = Body.from_json(body.to_json)
  end

  def initialize(aggregate_id : UUID, version : Int32)
    @header = Header.new(
      aggregate_id: aggregate_id,
      aggregate_type: "HandlerTest",
      aggregate_version: version,
      command_handler: "HandlerDecider",
      event_handle: @@handle
    )
    @body = Body.new
  end
end

# Pure decider for the handler spec
class HandlerDecider
  include ES::Decider(HandlerCmd, HandlerState, HandlerEvent)

  def initial_state : HandlerState
    HandlerState.new(UUID.v7)
  end

  def decide(command : HandlerCmd, state : HandlerState) : ES::Decision(HandlerEvent)
    if command.should_accept
      ES::Decision(HandlerEvent).accept([
        HandlerEvent.new(aggregate_id: state.aggregate_id, version: state.next_version),
      ])
    else
      ES::Decision(HandlerEvent).reject("command said no")
    end
  end

  def evolve(state : HandlerState, event : HandlerEvent) : HandlerState
    state.processed += 1
    state.aggregate_version = event.header.aggregate_version
    state
  end
end

# Parse proc: raw store event → HandlerEvent
HANDLER_PARSE = ->(raw : ES::EventStore::Event) {
  h = ES::Event::Header.from_json(raw.header.to_json)
  HandlerEvent.new(h, raw.body)
}

# ---------------------------------------------------------------------------
# Specs
# ---------------------------------------------------------------------------

describe ES::CommandHandler do
  it "accepts a command and appends the resulting event" do
    store = ES::EventStoreAdapters::InMemory.new
    agg_id = UUID.v7
    dec = HandlerDecider.new
    handler = ES::CommandHandler(HandlerCmd, HandlerState, HandlerEvent).new(
      dec, store, HANDLER_PARSE
    )

    outcome = handler.handle(agg_id, HandlerCmd.new(should_accept: true))

    outcome.accepted?.should be_true
    store.fetch_events(agg_id).size.should eq(1)
  end

  it "rejects a command and appends nothing" do
    store = ES::EventStoreAdapters::InMemory.new
    agg_id = UUID.v7
    dec = HandlerDecider.new
    handler = ES::CommandHandler(HandlerCmd, HandlerState, HandlerEvent).new(
      dec, store, HANDLER_PARSE
    )

    outcome = handler.handle(agg_id, HandlerCmd.new(should_accept: false))

    outcome.rejected?.should be_true
    outcome.reason.should eq("command said no")
    store.fetch_events(agg_id).size.should eq(0)
  end

  it "folds prior events before deciding — second handle sees first event" do
    store = ES::EventStoreAdapters::InMemory.new
    agg_id = UUID.v7
    dec = HandlerDecider.new
    handler = ES::CommandHandler(HandlerCmd, HandlerState, HandlerEvent).new(
      dec, store, HANDLER_PARSE
    )

    # First command: appends version-1 event
    handler.handle(agg_id, HandlerCmd.new(should_accept: true))

    # Second command: handler folds the version-1 event, state.processed == 1,
    # next_version == 2 → emits a version-2 event
    handler.handle(agg_id, HandlerCmd.new(should_accept: true))

    events = store.fetch_events(agg_id)
    events.size.should eq(2)

    h2 = ES::Event::Header.from_json(events[1].header.to_json)
    h2.aggregate_version.should eq(2)
  end
end
