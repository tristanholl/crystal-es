require "../../spec_helper"

class MyEventStore < ES::EventStore
  def setup 
    # Noop
  end

  def append(event : ES::Event)
  end

  def fetch_events(aggregate_id : UUID) : Array(ES::EventStore::Event)
    [] of ES::EventStore::Event
  end

  def fetch_event(event_id : UUID) : ES::EventStore::Event
    nil
  end
end

describe ES::EventStore do
  it "allows to instantiate a child class" do
    store = MyEventStore.new
    store.class.should eq(MyEventStore)
  end
end

describe ES::EventStore::Event do
  it "should initialize with header and body JSON objects" do
    header = JSON.parse(%({"test": "header"}))
    body = JSON.parse(%({"test": "body"}))
    event = ES::EventStore::Event.new(header, body)

    event.header["test"].should eq("header")
    event.body["test"].should eq("body")
  end
end
