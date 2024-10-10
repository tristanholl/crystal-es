require "../../spec_helper"

class MyEvent < ES::Event
  @@handle = "myevent"

  struct Body < ES::Event::Body
    include JSON::Serializable

    def initialize(@comment)
    end
  end

  def initialize(@header : ES::Event::Header, body : JSON::Any)
    @body = Body.from_json(body.to_json)
  end

  def initialize
    @header = Header.new(
      aggregate_id: UUID.random,
      aggregate_type: "Test",
      aggregate_version: 1,
      command_handler: "test",
      event_handle: @@handle
    )
    @body = Body.new("comment")
  end
end

describe ES::EventStores::InMemory do
  it "can append, fetch single and all events", tags: "db" do
    store = ES::EventStores::InMemory.new
    event = MyEvent.new

    # Append
    store.append(event)

    event_id = event.header.event_id
    aggregate_id = event.header.aggregate_id

    # Fetch single event by id
    es_event_1 = store.fetch_event(event_id)
    h = ES::Event::Header.from_json(es_event_1.header.to_json)
    h.aggregate_id.should eq(aggregate_id)
    h.event_id.should eq(event_id)

    # Fetch events by aggregate_id
    es_events = store.fetch_events(aggregate_id)

    aggr_ids = [] of UUID
    event_ids = [] of UUID

    es_events.each do |es_event|
      h = ES::Event::Header.from_json(es_event_1.header.to_json)
      aggr_ids << h.aggregate_id
      event_ids << h.event_id
    end

    aggr_ids.should eq([aggregate_id])
    event_ids.should eq([event_id])
  end
end
