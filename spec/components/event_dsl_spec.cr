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

class EventDSLEncryptedEvent < ES::Event
  include ::ES::EventDSL

  define_event "Test3", "test.event.encrypted", encrypted: true do
    attribute :field1, String
  end
end

describe ES::EventDSL do
  it "Reports an undeclared event as not encrypted" do
    EventDSLTestEvent.encrypted?.should be_false
  end

  it "Reports a declared event as encrypted" do
    EventDSLEncryptedEvent.encrypted?.should be_true
  end

  it "Puts the key on the header of an encrypted event" do
    key_id = UUID.v7
    e = EventDSLEncryptedEvent.new(
      actor_id: nil, command_handler: "handler",
      encryption_key_id: key_id, field1: "field1"
    )

    e.header.encryption_key_id.should eq(key_id)
  end

  # `encryption_key_id` has no default on an encrypted event, so omitting it is a
  # compile error rather than a plaintext write. That is the point of the flag —
  # the check cannot be expressed as a runtime spec, only as its absence here.
  it "Leaves the key unset on an event that does not ask for one" do
    e = EventDSLTestEvent2.new(actor_id: nil, command_handler: "handler", field1: "field1")

    e.header.encryption_key_id.should be_nil
  end

  # An undeclared event's constructor has no `encryption_key_id` parameter at all,
  # so `EventDSLTestEvent2.new(..., encryption_key_id: key_id)` is a compile error.
  # That, too, can only be shown by its absence here rather than as a runtime spec.

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
