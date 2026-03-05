require "../spec_helper"

class EventDSLTestEvent < ES::Event
  include ::ES::EventDSL

  define_event "Test", "test.event"
end

class EventDSLTestEvent2 < ES::Event
  include ::ES::EventDSL

  define_event "Test2", "test.event.two" do
    attribute :field1, String
  end
end

class EventDSLTestEvent3 < ES::Event
  include ::ES::EventDSL

  define_event "Test2", "test.event.two" do
    attribute :field1, String, "bananas"
  end
end

describe ES::EventDSL do
  it "Creates event without fields" do
    e = EventDSLTestEvent.new(actor_id: nil, command_handler: "handler", comment: "test")
    e.body.comment.should eq("test")
  end

  it "Creates event with fields" do
    e = EventDSLTestEvent2.new(actor_id: nil, command_handler: "handler", field1: "field1")
    b = e.body.as(EventDSLTestEvent2::Body)

    b.field1.should eq("field1")
  end

  it "Creates event with fields and defaults" do
    e = EventDSLTestEvent3.new(actor_id: nil, command_handler: "handler")
    b = e.body.as(EventDSLTestEvent3::Body)

    b.field1.should eq("bananas")
  end
end
