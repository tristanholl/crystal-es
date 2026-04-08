require "../../spec_helper"

describe ES::EventStoreAdapters::InMemory do
  it "each_event yields all events in insertion order" do
    store = ES::EventStoreAdapters::InMemory.new
    e1 = DummyEvent.new
    e2 = DummyEvent.new
    e3 = DummyEvent.new
    store.append(e1)
    store.append(e2)
    store.append(e3)

    collected = [] of UUID
    store.each_event { |ev| collected << UUID.new(ev.header["event_id"].as_s) }
    collected.should eq([e1.header.event_id, e2.header.event_id, e3.header.event_id])
  end

  it "each_event stops at until_event_id (inclusive)" do
    store = ES::EventStoreAdapters::InMemory.new
    e1 = DummyEvent.new
    e2 = DummyEvent.new
    e3 = DummyEvent.new
    store.append(e1)
    store.append(e2)
    store.append(e3)

    collected = [] of UUID
    store.each_event(until_event_id: e2.header.event_id) { |ev| collected << UUID.new(ev.header["event_id"].as_s) }
    collected.should eq([e1.header.event_id, e2.header.event_id])
  end

  it "each_event raises NotFound for unknown until_event_id" do
    store = ES::EventStoreAdapters::InMemory.new
    unknown = UUID.v7
    expect_raises(ES::Exception::NotFound) do
      store.each_event(until_event_id: unknown) { }
    end
  end

  it "can append, fetch single and all events", tags: "db" do
    store = ES::EventStoreAdapters::InMemory.new
    event = DummyEvent.new

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
